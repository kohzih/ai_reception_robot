require "open3"

module RobotProcessTestSupport
  def fixture_process_factory(variant = "success", &observe)
    ->(environment, python, flag, script, **options) do
      observe&.call(environment, python, flag, script, options)
      Open3.popen3(environment, RbConfig.ruby, Rails.root.join("test/support/robot_process_fixture.rb").to_s,
                  variant, File.basename(script, ".py"), **options)
    end
  end

  def fixture_executor(variant = "success", **options)
    RobotExecutor.new(process_factory: fixture_process_factory(variant), termination_grace: 0.1, **options)
  end
end
