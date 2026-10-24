class CreateRobotRuns < ActiveRecord::Migration[8.1]
  def change
    create_table :robot_runs do |t|
      t.string :browser_id, null: false
      t.text :input_text, null: false
      t.boolean :preview, null: false, default: true
      t.string :preview_scenario
      t.string :status, null: false
      t.string :intent
      t.float :confidence
      t.string :action
      t.text :response_text, null: false
      t.string :error_code
      t.timestamps
    end
    add_index :robot_runs, [ :browser_id, :created_at, :id ]
  end
end
