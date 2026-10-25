class AddRobotProcessingState < ActiveRecord::Migration[8.1]
  def change
    add_column :robot_runs, :active_job_id, :string
    add_column :robot_runs, :worker_epoch, :string
    add_column :robot_runs, :queued_at, :datetime
    add_column :robot_runs, :enqueued_at, :datetime
    add_column :robot_runs, :started_at, :datetime
    add_column :robot_runs, :finished_at, :datetime
    change_column_default :robot_runs, :status, from: nil, to: "queued"
    change_column_default :robot_runs, :response_text, from: nil, to: ""

    create_table :robot_states do |t|
      t.string :status, null: false, default: "idle"
      t.references :current_run, foreign_key: { to_table: :robot_runs }
      t.bigint :worker_process_id
      t.string :worker_epoch
      t.boolean :worker_accepting, null: false, default: false
      t.timestamps
    end
    add_check_constraint :robot_states, "id = 1", name: "robot_state_singleton"
    execute "INSERT INTO robot_states (id, status, worker_accepting, created_at, updated_at) VALUES (1, 'idle', 0, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)"
  end
end
