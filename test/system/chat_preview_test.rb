require "application_system_test_case"
require_relative "../support/robot_system_worker"

class ChatPreviewSystemTest < ApplicationSystemTestCase
  self.use_transactional_tests = false
  include RobotSystemWorker
  setup :start_system_worker
  teardown :stop_system_worker
  test "Japanese messages show all preview responses and persist after reload" do
    visit root_path
    assert_text "仮応答モード"
    assert_button "仮応答を確認", disabled: true
    {
      "挨拶" => "お辞儀します。", "受付への案内" => "受付の方向を示します。",
      "講演会場への案内" => "講演会場の方向を示します。",
      "案内先が不明" => "案内先を特定できませんでした。保留の合図をします。",
      "信頼度が低い場合" => "案内先を特定できませんでした。保留の合図をします。",
      "判断処理の失敗" => "判断処理に失敗しました。もう一度お試しください。",
      "動作処理の失敗" => "動作の実行に失敗しました。"
    }.each_with_index do |(scenario, response), index|
      select scenario, from: "確認する仮応答"
      fill_in "メッセージ", with: "画面で日本語を確認 #{index}"
      click_button "仮応答を確認"
      assert_selector ".conversation-entry", count: index + 1
      assert_selector ".conversation-entry:last-of-type .assistant-bubble", text: response
      if scenario == "動作処理の失敗"
        assert_text "受付を停止しています。"
        assert_button "仮応答を確認", disabled: true
      else
        assert_text "入力できます"
      end
    end
    refresh
    assert_selector ".conversation-entry", count: 7
    assert_selector ".conversation-entry:last-of-type", text: "画面で日本語を確認 6"
    save_preview_screenshot("step12_desktop.png")
  end

  test "browser validation counts Unicode characters and blocks whitespace or 201 characters" do
    visit root_path
    fill_in "メッセージ", with: "　 \n"
    assert_button "仮応答を確認", disabled: true
    set_message("😀" * 201)
    assert_text "201 / 200"
    assert_button "仮応答を確認", disabled: true
    set_message("😀" * 200)
    assert_text "200 / 200"
    assert_button "仮応答を確認", disabled: false
    click_button "仮応答を確認"
    assert_selector ".visitor-bubble", text: "😀" * 200
    assert_text "入力できます"
    set_message("あ" * 198 + "\nい")
    assert_text "200 / 200"
    click_button "仮応答を確認"
    assert_selector ".visitor-bubble", text: "あ" * 198
  end

  test "Enter sends Shift Enter inserts a newline and IME confirmation never sends" do
    visit root_path
    page.execute_script(<<~JS)
      window.keyboardPosts = 0
      const original = window.fetch.bind(window)
      window.fetch = (url, options = {}) => {
        if (options.method === "POST") window.keyboardPosts += 1
        return original(url, options)
      }
    JS
    input = find_field("メッセージ")
    input.send_keys(:enter)
    assert_field "メッセージ", with: ""
    input.send_keys("受付", [ :shift, :enter ], "はどこですか？")
    assert_field "メッセージ", with: "受付\nはどこですか？"
    [ { isComposing: true }, { keyCode: 229 } ].each do |properties|
      prevented = page.evaluate_script(<<~JS, input, properties)
        ((input, properties) => {
          const event = new KeyboardEvent("keydown", { key: "Enter", bubbles: true, cancelable: true, ...properties })
          input.dispatchEvent(event)
          return event.defaultPrevented
        })(arguments[0], arguments[1])
      JS
      refute prevented
    end
    page.execute_script('arguments[0].dispatchEvent(new KeyboardEvent("keydown", {key: "Enter", repeat: true, bubbles: true, cancelable: true}))', input)
    assert_equal 0, page.evaluate_script("window.keyboardPosts")
    input.send_keys(:enter)
    assert_selector ".conversation-entry", count: 1
    assert_text "入力できます"
    assert_equal "受付\nはどこですか？", RobotRun.uncached { RobotRun.sole.input_text }
    set_message("あ" * 201)
    input.send_keys(:enter)
    assert_button "仮応答を確認", disabled: true
    assert_equal 1, page.evaluate_script("window.keyboardPosts")
  end

  test "input examples HTML text and narrow screens work without executing HTML" do
    visit root_path
    click_button "受付を探す"
    assert_field "メッセージ", with: "参加受付はどこですか？"
    assert_selector "#robot_run_preview_scenario option:checked", text: "受付への案内"
    payload = '<img src=x onerror="window.__previewXss=true"><script>window.__previewXss=true</script>'
    fill_in "メッセージ", with: payload
    click_button "仮応答を確認"
    assert_selector ".visitor-bubble", text: payload
    assert_no_selector ".visitor-bubble img, .visitor-bubble script"
    assert_nil page.evaluate_script("window.__previewXss")
    page.driver.browser.manage.window.resize_to(390, 844)
    assert_operator page.evaluate_script("document.documentElement.scrollWidth"), :<=, page.evaluate_script("window.innerWidth")
    save_preview_screenshot("step12_mobile.png")
  ensure
    page.driver.browser.manage.window.resize_to(1280, 960)
  end

  test "two tabs reject overlapping submissions and reload restores an active run" do
    Rails.configuration.x.robot_preview_stage_seconds = 1.2
    visit root_path
    second = open_new_window
    within_window(second) do
      visit root_path
      fill_in "メッセージ", with: "別タブの入力"
    end
    fill_in "メッセージ", with: "処理中に画面を再読み込み"
    click_button "仮応答を確認"
    assert_selector ".conversation-entry", count: 1
    refresh
    assert_selector ".visitor-bubble", text: "処理中に画面を再読み込み"
    assert_button "仮応答を確認", disabled: true
    within_window(second) do
      page.execute_script("document.querySelector('#chat-form').dispatchEvent(new Event('submit', { bubbles: true, cancelable: true }))")
    end
    assert_equal 1, RobotRun.count
    save_preview_screenshot("step12_processing.png")
    assert_text "入力できます"
    assert_selector ".conversation-entry", count: 1
    second.close
  end

  test "restarting a real worker keeps an unfinished run blocked without replay" do
    Rails.configuration.x.robot_preview_stage_seconds = 1.5
    visit root_path
    fill_in "メッセージ", with: "再起動時の未完了記録"
    click_button "仮応答を確認"
    assert_selector '.conversation-entry[data-run-status="classifying"]'
    run = RobotRun.order(:id).last
    epoch, started = run.worker_epoch, run.started_at
    @system_worker.stop
    assert_equal "recovery_required", run.reload.status
    assert_equal run.id, RobotState.singleton.current_run_id
    @system_worker = SolidQueue::Worker.new(queues: [ "robot" ], threads: 1, polling_interval: 0.05, mode: :async)
    @system_worker.start
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
    until RobotState.singleton.worker_online?
      if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
        raise "Restart failed: #{RobotState.singleton.attributes.slice('status', 'worker_process_id', 'worker_accepting')} processes=#{SolidQueue::Process.pluck(:id, :kind)}"
      end
      sleep 0.02
    end
    refute_equal epoch, RobotState.singleton.worker_epoch
    refresh
    assert_text "受付を停止しています。"
    assert_button "仮応答を確認", disabled: true
    assert_equal started, run.reload.started_at
    assert_nil run.finished_at
    assert_equal run.id, RobotState.singleton.current_run_id
  end

  test "lost submission acknowledgement requires reload and never repeats the job" do
    visit root_path
    page.execute_script(<<~JS)
      const original = window.fetch.bind(window)
      window.fetch = async (url, options = {}) => {
        const response = await original(url, options)
        if (options.method === "POST") throw new TypeError("Lost acknowledgement")
        return response
      }
    JS
    fill_in "メッセージ", with: "送信結果が届かない場合"
    click_button "仮応答を確認"
    assert_text "送信結果を確認できません。再読み込みしてください。"
    assert_button "仮応答を確認", disabled: true
    assert_equal 1, RobotRun.count
    refresh
    assert_selector ".visitor-bubble", text: "送信結果が届かない場合"
    assert_text "入力できます"
    assert_equal 1, RobotRun.count
    assert_equal "previewed", RobotRun.sole.status
  end

  test "a stalled state request times out and polling resumes after reconnection" do
    visit root_path
    fill_in "メッセージ", with: "通信の復帰確認"
    page.execute_script(<<~JS)
      window.originalFetch = window.fetch.bind(window)
      window.fetch = (url, options = {}) => {
        if (String(url).includes("/chat/state")) {
          return new Promise((resolve, reject) => {
            options.signal.addEventListener("abort", () => reject(new DOMException("Timeout", "AbortError")), { once: true })
          })
        }
        return window.originalFetch(url, options)
      }
    JS
    assert_text "接続を確認しています。", wait: 8
    assert_button "仮応答を確認", disabled: true
    page.execute_script("window.fetch = window.originalFetch")
    assert_text "入力できます"
    assert_button "仮応答を確認", disabled: false
    assert_equal 0, RobotRun.count
  end

  test "administrator pause persists across reload and blocks keyboard submission" do
    visit root_path
    fill_in "メッセージ", with: "停止中の送信"
    RobotState.pause!
    refresh
    assert_text "ただいま受付を停止しています。"
    assert_button "仮応答を確認", disabled: true
    find_field("メッセージ").send_keys(:enter)
    assert_no_selector ".conversation-entry"
    assert_equal 0, RobotRun.uncached { RobotRun.count }
  end

  private

  def set_message(text)
    page.execute_script("arguments[0].value = arguments[1]; arguments[0].dispatchEvent(new Event('input', { bubbles: true }))", find_field("メッセージ"), text)
  end

  def save_preview_screenshot(name)
    FileUtils.mkdir_p(Rails.root.join("tmp/screenshots"))
    page.save_screenshot(Rails.root.join("tmp/screenshots", name))
  end
end
