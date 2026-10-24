require "test_helper"
require "selenium-webdriver"

Selenium::WebDriver.logger.level = :warn

class ApplicationSystemTestCase < ActionDispatch::SystemTestCase
  driven_by :selenium, using: :headless_chrome, screen_size: [ 1280, 960 ] do |options|
    options.add_argument("--no-sandbox")
    options.add_argument("--disable-dev-shm-usage")
  end
end
