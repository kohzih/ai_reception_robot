class AddRobotRecoveryState < ActiveRecord::Migration[8.1]
  def change
    add_column :robot_states, :maintenance, :boolean, default: false, null: false
    add_column :robot_states, :recovery_checked_at, :datetime
    add_column :robot_runs, :recovered_at, :datetime
    add_column :robot_runs, :recovery_details, :json, default: {}, null: false
    add_column :robot_runs, :robot_process, :json, default: {}, null: false
  end
end
