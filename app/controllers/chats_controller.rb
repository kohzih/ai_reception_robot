class ChatsController < ApplicationController
  before_action :identify_browser

  def index
    @robot_run = RobotRun.new(preview_scenario: "reception")
    load_history
  end

  def create
    attributes = params.expect(robot_run: [ :input_text, :preview_scenario ])
    run = RobotSubmission.call(browser_id: session.fetch(:browser_id), attributes: attributes)
    respond_to do |format|
      format.json { render json: { run_id: run.id, run_url: robot_run_path(run), screen: RobotScreenState.call(session.fetch(:browser_id)) }, status: :accepted }
      format.html { redirect_to root_path, status: :see_other }
    end
  rescue ActiveRecord::RecordInvalid => error
    @robot_run = error.record
    respond_error(@robot_run.errors.map(&:message).uniq.join(" "), :unprocessable_entity)
  rescue RobotSubmission::Unavailable => error
    @robot_run = RobotRun.new(attributes)
    @robot_run.errors.add(:base, error.message)
    respond_error(error.message, error.http_status)
  end

  def show
    run = browser_runs.find(params[:id])
    render json: run.as_json(only: %i[id preview preview_scenario status intent confidence action response_text error_code started_at finished_at])
                    .merge("status_label" => run.status_label)
  end

  def state
    render json: RobotScreenState.call(session.fetch(:browser_id))
  end

  def history
    load_history
    render :history, layout: false
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
    @screen = RobotScreenState.call(session.fetch(:browser_id))
  end

  def respond_error(message, status)
    respond_to do |format|
      format.json { render json: { message: message, screen: RobotScreenState.call(session.fetch(:browser_id)) }, status: status }
      format.html do
        load_history
        render :index, status: status
      end
    end
  end
end
