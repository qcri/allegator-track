require 'set'

class Runset < ActiveRecord::Base
  belongs_to :user
  has_and_belongs_to_many :datasets
  has_many :dataset_rows, through: :datasets

  has_many :runs, dependent: :destroy
  has_many :source_results, through: :runs
  has_many :claim_results, through: :runs

  def status
    run_statuses = self.runs.map(&:status).uniq
    # return finished if all runs are finished
    return "finished" if run_statuses == ["finished"]
    # return started if at least 1 run started
    return "started" if run_statuses.include?("started")
    # return combinable if all scheduled are combiners and all combiners are scheduled
    return "combinable" if Set.new(scheduled_runs) == Set.new(combiner_runs)
    # return scheduled otherwise
    return "scheduled"
  end

  def combiner_runs
    runs.select &:combiner?
  end

  def non_combiner_runs
    runs.reject &:combiner?
  end

  def scheduled_runs
    runs.select &:scheduled?
  end

  def runs
    Run.voters.joins(:runset).where("runsets.id = ?", self.id)
  end

  def claim_datasets
    datasets.where(kind: 'claims')
  end

  def ground_datasets
    datasets.where(kind: 'ground')
  end

  def as_json(options={})
    options = {
      :only => [:id, :created_at],
      :methods => [:runs, :claim_datasets, :ground_datasets]
    }.merge(options)
    super(options)
  end

  def to_s
    "Runset ##{id}"
  end

  def dataset_names
    datasets.where("datasets.kind = 'claims'").pluck(:original_filename).map do |filename|
      # remove extension
      File.basename(filename, File.extname(filename))
    end.join("_")
  end

  def results(params)
    run_ids = runs.map(&:id)
    normalized = params[:extra_normalized].present?
    results_type = case "#{params[:extra_only]}"
    when "source_id"
      :trustworthiness
    when ""
      :confidence
    end
    order, order_columns, default_order = params[:order], params[:columns], ""
    search = params[:search].try(:[], :value)
    search_object_key = params[:extra_object_key_criteria]
    search_source_id = params[:extra_source_id_criteria]
    claim_cols = %w(object_key property_key property_value source_id timestamp parent_id)
    claim_cols_s = claim_cols.join(", ")
    result, count_col = "normalized", nil
    query, counts_query = nil, nil
    allegated_claim_ids = []

    if results_type == :trustworthiness
      result = "trustworthiness" unless normalized
      query = SourceResult.select("
        source_id,
        array_to_string(array_agg(run_id ORDER BY run_id), E',') run_ids,
        array_to_string(array_agg(#{result} ORDER BY run_id), E',') result
      ").group(:source_id)
      .where("source_results.run_id" => run_ids)
      counts_query = SourceResult.where(run_id: run_ids.first)
      count_col = "source_id"
      default_order = "source_id"
    elsif results_type == :confidence
      # we need to highlight claims that were affected by allegations
      # get potential claim ids from runset datasets and highlight matching claims in results
      allegated_claim_ids = ActiveRecord::Base.connection.select_values("
        SELECT r.allegates_claim_id
        FROM datasets ds
        INNER JOIN runs r ON r.id = ds.allegated_by_run_id 
        WHERE ds.allegated_by_run_id IS NOT NULL
        AND ds.id IN (#{self.datasets.pluck(:id).join(',')});
      ").map(&:to_i) rescue []  # self.datasets could be deleted

      result = "confidence" unless normalized
      select = "
        dataset_rows.id claim_id, #{claim_cols_s},
        array_to_string(array_agg(run_id ORDER BY run_id), E',') run_ids,
        array_to_string(array_agg(round(#{result} * 10000)/10000 ORDER BY run_id), E',') result,
        array_to_string(array_agg(is_true ORDER BY run_id), E',') are_true
      "
      select << ", array_agg(claim_id in (#{allegated_claim_ids.join(',')})) allegated" if allegated_claim_ids.length > 0
      query = DatasetRow.select(select).joins("
        INNER JOIN claim_results ON dataset_rows.id = claim_results.claim_id
      ").group("dataset_rows.id").where("claim_results.run_id" => run_ids)
      counts_query = dataset_rows.where("datasets.kind = ?", "claims")
      count_col = "dataset_rows.id"
      default_order = "claim_id"
    end

    # totals
    logger.info("Counting total")
    total = counts_query.count("distinct #{count_col}")

    # sorting
    query = query.order("allegated desc") if allegated_claim_ids.length > 0
    if order
      sort = order["0"]
      sort_col = order_columns[sort["column"]]["data"]
      sort_dir = sort["dir"]
      if sort_col.match(/^r(\d+)$/) # need to order by run result, order by result array element
        run_id = $~[1] # last match: run_id
        sort_col = "(array_agg(#{result} ORDER BY run_id))[idx(array_agg(run_id ORDER BY run_id), #{run_id})]"
      end
      query = query.order("#{sort_col} #{sort_dir}")
    else
      query = query.order(default_order)
    end

    # filtering
    filtered = total
    logger.info("Counting filtered")
    if search.present?
      fields = results_type == :confidence ? %w(object_key source_id property_key property_value timestamp) : %w(source_id)
      clauses = fields.map{|f| "LOWER(#{f}) like LOWER('%#{search}%')"}
      clauses << "dataset_rows.id = #{search}" if search.to_i > 0
      clauses = clauses.join(" OR ")
      query, counts_query = query.where(clauses), counts_query.where(clauses)
    end
    # don't filter on object_id/source_id when showing source results
    # in object_id case, can't get object_id from source_results without join
    # in source_id case, the filter has been already used
    if results_type == :confidence
      if search_object_key.present?
        clause = "(LOWER(object_key) like LOWER('%#{search_object_key}%'))"
        query, counts_query = query.where(clause), counts_query.where(clause)
      end
      if search_source_id.present?
        clause = "(LOWER(source_id) like LOWER('%#{search_source_id}%'))"
        query, counts_query = query.where(clause), counts_query.where(clause)
      end
    end
    filtered = counts_query.count("distinct #{count_col}")

    return total, filtered, results_type, claim_cols, query
  end

  def hash_results(query, results_type, claim_cols)
    case results_type
    when :trustworthiness
      query.map do |row|
        hash = {"source_id" => row["source_id"]}
        run_ids = row["run_ids"].split(',')
        values = row["result"].split(',')
        run_ids.each_with_index {|run_id, index| hash["r#{run_id}"] = values[index]}
        hash
      end
    when :confidence
      query.map do |row|
        hash = claim_cols.reduce({"claim_id" => row["claim_id"]}) {|map, col|
          map[col] = row[col]
          map
        }
        run_ids = row["run_ids"].split(',')
        values = row["result"].split(',')
        are_true = row["are_true"].split(',')
        run_ids.each_with_index {|run_id, index| hash["r#{run_id}"], hash["r#{run_id}_bool"] = values[index], are_true[index]}
        hash["allegated"] = 1 if row["allegated"].try(:include?, true)
        hash
      end
    end
  end

end
