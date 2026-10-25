# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_10_25_040000) do
  create_table "robot_runs", force: :cascade do |t|
    t.string "browser_id", null: false
    t.text "input_text", null: false
    t.boolean "preview", default: true, null: false
    t.string "preview_scenario"
    t.string "status", default: "queued", null: false
    t.string "intent"
    t.float "confidence"
    t.string "action"
    t.text "response_text", default: "", null: false
    t.string "error_code"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "active_job_id"
    t.string "worker_epoch"
    t.datetime "queued_at"
    t.datetime "enqueued_at"
    t.datetime "started_at"
    t.datetime "finished_at"
    t.string "classification_model"
    t.integer "input_tokens"
    t.json "intent_probabilities", default: {}, null: false
    t.string "selection_reason"
    t.integer "classification_duration_ms"
    t.integer "robot_duration_ms"
    t.integer "robot_exit_code"
    t.datetime "command_sent_at"
    t.datetime "motion_completed_at"
    t.json "robot_events", default: [], null: false
    t.index ["browser_id", "created_at", "id"], name: "index_robot_runs_on_browser_id_and_created_at_and_id"
  end

  create_table "robot_states", force: :cascade do |t|
    t.string "status", default: "idle", null: false
    t.integer "current_run_id"
    t.bigint "worker_process_id"
    t.string "worker_epoch"
    t.boolean "worker_accepting", default: false, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["current_run_id"], name: "index_robot_states_on_current_run_id"
    t.check_constraint "id = 1", name: "robot_state_singleton"
  end

  add_foreign_key "robot_states", "robot_runs", column: "current_run_id"
end
