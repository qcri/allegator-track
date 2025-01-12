require 'csv'

class RunsetsController < ApplicationController

  # for csv export streaming
  # include ActionController::Live

  before_filter :authenticate_user_from_token!
  before_filter :authenticate_user!
  load_and_authorize_resource :except => [:create, :index]

  def create
    # try all user datasets
    datasets = current_user.datasets.pluck(:id)
    if datasets.length == 0
      render json: {error: "You don't have any datasets yet, please upload at least 1 dataset"}
      return
    end

    # try selected datasets
    if params[:datasets].present? && params[:datasets].respond_to?(:keys)
      datasets = params[:datasets].keys.map(&:to_i) & datasets
      if datasets.length == 0
        render json: {error: "You haven't specified valid datasets to use"}
        return
      end
    else
      render json: {error: "You haven't specified any datasets to use"}
      return
    end

    runset = Runset.create user: current_user, dataset_ids: datasets
    params[:checked_algo].each do |algo_name, algo_params|
      run = Run.new(runset_id: runset.id, algorithm: algo_name,
        general_config: params[:general_config].join(" "),
        config: algo_params.try(:join, " "))
      unless run.combiner?  # running combiners explicitly not allowed
        run.save
        run.delay.start
      end
    end
    # force run combiners if 2+ algorithms selected and 1+ ground dataset selected
    if runset.runs.length >= 2 && (Dataset.where(kind: 'ground').where(id: datasets).count) >= 1
      Run::COMBINER_ALGORITHMES.each do |combiner|
        Run.create(runset_id: runset.id, algorithm: combiner)
      end
    end

    render json: runset
  end

  def index
    runsets = current_user.runsets

    render json: runsets
  end

  def destroy
    @runset.destroy
    render json: {status: 'OK'}
  end

  def results
    total, filtered, results_type, claim_cols, query = @runset.results(params)

    respond_to do |format|
      format.json {
        # showing table, apply offset/limit
        query = limit_query(query)
        logger.info("Retrieving results from arel generated sql: #{query.to_sql}")

        data = @runset.hash_results(query, results_type, claim_cols)

        render json: {
          draw: params[:draw].to_i,
          recordsTotal: total,
          recordsFiltered: filtered,
          data: data
        }        
      }
      format.csv {
        # exporting csv, retrieve all data at once!
        logger.info("Exporting results from arel generated sql: #{query.to_sql}")

        filename = params[:extra_only] == "source_id" ? "source" : "claim"

        headers['Content-Disposition'] = "attachment; filename=#{filename}_results_runset_#{@runset.id}_#{@runset.dataset_names}.csv"
        headers['X-Accel-Buffering'] = 'no'
        headers['Cache-Control'] = 'no-cache'

        self.response_body = Enumerator.new do |receiver|
          start, length = 0, 1000
          while start < filtered
            params[:start], params[:length] = start, length
            data = @runset.hash_results(limit_query(query), results_type, claim_cols)

            receiver << CSV.generate_line(data[0].keys.map{|key|
              m = key.match(/^r([\d]+)$/)
              key + (m ? ": #{Run.find(m[1].to_i).display}" : "")
            }) if start == 0

            data.each do |row|
              receiver << CSV.generate_line(row.values)
            end

            puts "written chunk of #{length} lines starting from #{start}"

            start += length
          end
        end

      }
    end

  end

end
