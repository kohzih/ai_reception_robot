class ChatsController < ApplicationController
  before_action :identify_browser

  def index
    @robot_run = RobotRun.new(preview_scenario: "reception")
    load_history
  end

  def create
    @robot_run = browser_runs.new(params.expect(robot_run: [ :input_text, :preview_scenario ]))
    @robot_run.preview = true
    if @robot_run.save
      redirect_to root_path, status: :see_other
    else
      load_history
      render :index, status: :unprocessable_entity
    end
  end

  def show
    run = browser_runs.find(params[:id])
    render json: run.as_json(only: %i[id preview preview_scenario status intent confidence action response_text error_code])
  end

  private

  def identify_browser
    session[:browser_id] ||= SecureRandom.uuid
    response.headers["Cache-Control"] = "no-store"
  end

  def browser_runs
    RobotRun.for_browser(session.fetch(:browser_id))
  end

  def load_history
    @runs = browser_runs.order(created_at: :desc, id: :desc).limit(RobotRun::HISTORY_LIMIT).reverse
  end
end
