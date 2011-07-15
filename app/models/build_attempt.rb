class BuildAttempt < ActiveRecord::Base
  has_many :build_artifacts
  belongs_to :build_part

  STATES = [:runnable, :running, :passed, :failed, :error]
  symbolize :state, :in => STATES
  STATES.each do |state|
    scope state, where(:state => state.to_s)
  end

  def elapsed_time
    if finished_at && started_at
      finished_at - started_at
    elsif started_at
      Time.now - started_at
    else
      nil
    end
  end

  def start!(builder)
    update_attributes(:state => :running, :started_at => Time.now, :builder => builder)
  end

  def finish!(state)
    update_attributes(:state => state, :finished_at => Time.now)
  end

  def error!
    update_attributes(:state => :error, :finished_at => Time.now)
  end

  def unsuccessful?
    state == :failed || state == :error
  end
end