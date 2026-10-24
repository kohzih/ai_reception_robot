require "application_system_test_case"

class ChatPreviewSystemTest < ApplicationSystemTestCase
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
      assert_text "入力できます"
    end
    refresh
    assert_selector ".conversation-entry", count: 7
    assert_selector ".conversation-entry:last-of-type", text: "画面で日本語を確認 6"
    save_preview_screenshot("step11_desktop.png")
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
    set_message("あ" * 198 + "\nい")
    assert_text "200 / 200"
    click_button "仮応答を確認"
    assert_selector ".visitor-bubble", text: "あ" * 198
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
    save_preview_screenshot("step11_mobile.png")
  ensure
    page.driver.browser.manage.window.resize_to(1280, 960)
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
