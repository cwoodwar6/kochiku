class AddSendBuildFailureEmailToRepository < ActiveRecord::Migration[5.0]
  def change
    add_column :repositories, :send_build_failure_email, :boolean, :default => true
  end
end
