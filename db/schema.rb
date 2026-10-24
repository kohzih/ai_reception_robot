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

ActiveRecord::Schema[8.1].define(version: 2026_10_25_000000) do
  create_table "robot_runs", force: :cascade do |t|
    t.string "browser_id", null: false
    t.text "input_text", null: false
    t.boolean "preview", default: true, null: false
    t.string "preview_scenario"
    t.string "status", null: false
    t.string "intent"
    t.float "confidence"
    t.string "action"
    t.text "response_text", null: false
    t.string "error_code"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["browser_id", "created_at", "id"], name: "index_robot_runs_on_browser_id_and_created_at_and_id"
  end
end
