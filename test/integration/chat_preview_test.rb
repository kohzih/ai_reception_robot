require "test_helper"

class ChatPreviewTest < ActionDispatch::IntegrationTest
  test "seven fixture responses are stored and rendered without calling Clef" do
    expected = {
      "greeting" => [ "bow", "お辞儀します。" ], "reception" => [ "reception", "受付の方向を示します。" ],
      "hall" => [ "hall", "講演会場の方向を示します。" ],
      "unknown" => [ "hold", "案内先を特定できませんでした。保留の合図をします。" ],
      "low_confidence" => [ "hold", "案内先を特定できませんでした。保留の合図をします。" ],
      "classification_error" => [ nil, "判断処理に失敗しました。もう一度お試しください。" ],
      "robot_error" => [ "hall", "動作の実行に失敗しました。" ]
    }
    guard = TracePoint.new(:call) do |event|
      flunk "Preview must not call Clef" if event.defined_class == ClefClient && %i[initialize classify].include?(event.method_id)
    end
    guard.enable do
      get root_path
      expected.each do |scenario, (action, message)|
        assert_difference "RobotRun.count", 1 do
          post chat_path, params: { robot_run: { input_text: "日本語の表示確認 #{scenario}", preview_scenario: scenario } }
        end
        assert_response :see_other
        run = RobotRun.order(:id).last
        assert run.preview?
        if action.nil?
          assert_nil run.action
        else
          assert_equal action, run.action
        end
        assert_equal message, run.response_text
        refute_equal "completed", run.status
        follow_redirect!
        assert_select ".assistant-bubble", text: message
        assert_select ".mode-badge", text: "仮応答モード"
      end
    end
    assert_equal 7, RobotRun.distinct.count(:preview_scenario)
  end

  test "API credentials never appear in HTML or the state response" do
    keys = %w[CLOUDFLARE_ACCOUNT_ID CLOUDFLARE_API_TOKEN]
    previous = keys.to_h { |key| [ key, ENV[key] ] }
    ENV["CLOUDFLARE_ACCOUNT_ID"] = "test-account-do-not-render"
    ENV["CLOUDFLARE_API_TOKEN"] = "test-token-do-not-render"
    post chat_path, params: { robot_run: { input_text: "こんにちは", preview_scenario: "greeting" } }
    follow_redirect!
    refute_includes response.body, "test-account-do-not-render"
    refute_includes response.body, "test-token-do-not-render"
    get robot_run_path(RobotRun.order(:id).last), as: :json
    refute_includes response.body, "test-account-do-not-render"
    refute_includes response.body, "test-token-do-not-render"
  ensure
    previous&.each { |key, value| ENV[key] = value }
  end

  test "server rejects blank overlong and malformed submissions without storing them" do
    get root_path
    [ "", "　 \n", "あ" * 201, [ "text" ], { text: "nested" } ].each do |input|
      assert_no_difference "RobotRun.count" do
        post chat_path, params: { robot_run: { input_text: input, preview_scenario: "reception" } }
      end
      assert_response :unprocessable_entity
      assert_select "[role=alert]"
    end
    assert_no_difference "RobotRun.count" do
      post chat_path, params: { robot_run: { input_text: "こんにちは", preview_scenario: "invalid" } }
    end
    assert_response :unprocessable_entity
    post chat_path, params: { robot_run: "invalid" }
    assert_response :bad_request
  end

  test "HTML input is displayed as text and survives reloading" do
    payload = '<script>window.__previewXss = true</script><img src=x onerror="alert(1)">'
    post chat_path, params: { robot_run: { input_text: payload, preview_scenario: "unknown" } }
    assert_response :see_other
    follow_redirect!
    assert_select ".visitor-bubble", text: payload
    assert_select ".visitor-bubble script, .visitor-bubble img", count: 0
    get root_path
    assert_select ".visitor-bubble", text: payload
    assert_match(/no-store/, response.headers["Cache-Control"])
  end

  test "browser isolation covers history state reads and forged ownership fields" do
    first, other = open_session, open_session
    first.post chat_path, params: { robot_run: { input_text: "最初のブラウザだけの入力", preview_scenario: "reception" } }
    run = RobotRun.order(:id).last
    other.get root_path
    refute_includes other.response.body, run.input_text
    other.get robot_run_path(run), as: :json
    other.assert_response :not_found
    first.get robot_run_path(run), as: :json
    first.assert_response :success
    assert_equal true, first.response.parsed_body["preview"]
    refute first.response.parsed_body.key?("browser_id")
    other.post chat_path, params: { robot_run: {
      input_text: "別のブラウザの入力", preview_scenario: "hall", browser_id: run.browser_id,
      preview: false, status: "completed", response_text: "偽の完了"
    } }
    forged = RobotRun.order(:id).last
    refute_equal run.browser_id, forged.browser_id
    assert forged.preview?
    assert_equal "previewed", forged.status
    assert_equal "講演会場の方向を示します。", forged.response_text
    first.get root_path
    refute_includes first.response.body, forged.input_text
  end

  test "forgery protection rejects missing tokens and accepts the same browser token" do
    previous = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = true
    get root_path
    token = Nokogiri::HTML(response.body).at_css('meta[name="csrf-token"]')["content"]
    assert_no_difference "RobotRun.count" do
      post chat_path, params: { robot_run: { input_text: "こんにちは", preview_scenario: "greeting" } }
    end
    assert_response :unprocessable_entity
    assert_difference "RobotRun.count", 1 do
      post chat_path, params: { authenticity_token: token, robot_run: { input_text: "こんにちは", preview_scenario: "greeting" } }
    end
    assert_response :see_other
  ensure
    ActionController::Base.allow_forgery_protection = previous
  end
end
