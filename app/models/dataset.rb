class Dataset < ActiveRecord::Base
  belongs_to :user
  has_many :dataset_rows, dependent: :destroy, autosave: true
  has_and_belongs_to_many :runsets

  def to_s
    self.original_filename
  end

  def parse_upload
    require 'csv'
    csv_opts = {:headers => true, :return_headers => false, :header_converters => :symbol, :converters => :all}
    CSV.foreach(read_file, csv_opts) do |row|
      DatasetRow.initialize_from_row(row, self)
    end
    self.save!
  end

  def row_count
    self.dataset_rows.count
  end

  def export(path)
    require 'csv'
    CSV.open(path, "wb") do |csv|
      csv << DatasetRow.export_header
      dataset_rows.each do |row|
        csv << row.export
      end
    end
  end

  def as_json(options={})
    options = {
      :only => [:id, :kind, :original_filename, :created_at],
      :methods => [:row_count]
    }.merge(options)
    super(options)
  end

  def destroy
    # overriding destroy to be more efficient by issuing only 3 SQL deletes
    # rather than 1 + dataset_rows.count !
    conn = ActiveRecord::Base.connection
    conn.execute("DELETE FROM dataset_rows WHERE dataset_id = #{self.id}")    
    super # continue from super to call all after_destroy callbacks
  end

private
  
  def read_file
    # streaming download from S3
    file = Tempfile.new("import-#{self.id}-")
    S3_BUCKET.objects[self.s3_key].read do |chunk|
      file.write chunk
    end
    file.close
    file.path
  end
end
