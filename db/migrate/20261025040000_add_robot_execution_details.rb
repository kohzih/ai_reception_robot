class AddRobotExecutionDetails < ActiveRecord::Migration[8.1]
  def change
    add_column :robot_runs, :classification_model, :string
    add_column :robot_runs, :input_tokens, :integer
    add_column :robot_runs, :intent_probabilities, :json, null: false, default: {}
    add_column :robot_runs, :selection_reason, :string
    add_column :robot_runs, :classification_duration_ms, :integer
    add_column :robot_runs, :robot_duration_ms, :integer
    add_column :robot_runs, :robot_exit_code, :integer
    add_column :robot_runs, :command_sent_at, :datetime
    add_column :robot_runs, :motion_completed_at, :datetime
    add_column :robot_runs, :robot_events, :json, null: false, default: []
  end
end
