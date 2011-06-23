class Build < ActiveRecord::Base
  has_many :build_parts
  has_many :build_part_results, :through => :build_parts
  symbolize :state, :in => [:partitioning, :runnable, :running, :doomed, :failed, :succeeded, :error]
  symbolize :queue
  validates_presence_of :queue

  after_create :enqueue_partitioning_job

  def self.build_sha!(attributes)
    Build.create!(attributes.merge(:state => :partitioning))
  end

  def enqueue_partitioning_job
    Resque.enqueue(BuildPartitioningJob, self.id)
  end

  def partition(parts)
    transaction do
      update_attributes!(:state => :runnable)
      parts.each { |part| build_parts.create!(:kind => part['type'], :paths => part['files']) }
    end
  end

  def update_state_from_parts!
    return if build_parts.empty?
    passed = build_parts.passed
    failed = build_parts.failed
    state =
      if (build_parts - passed).empty?
        :succeeded
      elsif (passed | failed) == build_parts
        :failed
      else
         failed.empty? ? :running : :doomed
      end
    update_attributes!(:state => state)
  end

  def started_at
    build_part_results.order('started_at asc').first.started_at
  end

  def finished_at
#    build_part_results.all.sort_by(&:finished_at).last
  end

  def finished?
    state == :succeeded || state == :failed
  end

  def promotable?
    queue == :master
  end

  def promotion_ref
    "ci-master-distributed-latest" if promotable?
  end
end
