class AddTestCommandToBuilds < ActiveRecord::Migration[5.0]
  def change
    add_column :builds, :test_command, :string
  end
end
