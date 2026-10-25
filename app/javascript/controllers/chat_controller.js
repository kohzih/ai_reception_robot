import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["input", "counter", "submit", "status", "messages", "scenario", "errors", "history"]
  static values = { maxCharacters: Number, available: Boolean, stateMessage: String, historyVersion: String, stateUrl: String, historyUrl: String, sendLabel: { type: String, default: "仮応答を確認 ↑" } }

  connect() {
    this.busy = false
    this.deliveryUncertain = false
    this.update()
    this.messagesTarget.scrollTop = this.messagesTarget.scrollHeight
    this.timer = window.setInterval(() => this.poll(), 1000)
    this.poll()
  }

  disconnect() {
    window.clearInterval(this.timer)
    this.request?.abort()
    this.submission?.abort()
  }

  update() {
    const length = Array.from(this.inputTarget.value).length
    const blank = this.inputTarget.value.trim().length === 0
    const tooLong = length > this.maxCharactersValue
    this.counterTarget.textContent = `${length} / ${this.maxCharactersValue}`
    this.counterTarget.classList.toggle("over-limit", tooLong)
    this.inputTarget.setCustomValidity(blank ? "メッセージを入力してください。" : (tooLong ? "200文字以内で入力してください。" : ""))
    const blocked = this.busy || !this.availableValue || this.deliveryUncertain
    this.submitTarget.disabled = blank || tooLong || blocked
    this.inputTarget.readOnly = blocked
    if (this.hasScenarioTarget) this.scenarioTarget.disabled = blocked
    this.statusTarget.textContent = this.deliveryUncertain ? "送信結果を確認できません。再読み込みしてください。" : (this.busy ? "受付中…" : this.stateMessageValue)
    this.submitTarget.textContent = this.busy ? "受付中…" : this.sendLabelValue
  }

  example({ params }) {
    if (this.busy || !this.availableValue || this.deliveryUncertain) return
    this.inputTarget.value = params.text
    if (this.hasScenarioTarget) this.scenarioTarget.value = params.scenario
    this.update()
    this.inputTarget.focus()
  }

  async send(event) {
    event.preventDefault()
    if (this.submitTarget.disabled || !event.target.reportValidity()) return
    const body = new FormData(event.target)
    this.busy = true
    this.errorsTarget.hidden = true
    this.update()
    this.submission = new AbortController()
    const timeout = window.setTimeout(() => this.submission.abort(), 10000)
    try {
      const response = await fetch(event.target.action, {
        method: "POST", body, credentials: "same-origin",
        signal: this.submission.signal,
        headers: { "Accept": "application/json", "X-CSRF-Token": document.querySelector('meta[name="csrf-token"]')?.content || "" }
      })
      const data = await response.json()
      if (response.status === 202) {
        this.inputTarget.value = ""
        this.deliveryUncertain = false
      } else {
        this.errorsTarget.textContent = data.message || "受付できませんでした。"
        this.errorsTarget.hidden = false
      }
      if (data.screen) await this.applyScreen(data.screen, response.status === 202)
    } catch {
      this.deliveryUncertain = true
    } finally {
      window.clearTimeout(timeout)
      this.busy = false
      this.update()
    }
  }

  async poll() {
    if (this.polling) return
    this.polling = true
    this.request = new AbortController()
    const timeout = window.setTimeout(() => this.request.abort(), 5000)
    try {
      const response = await fetch(this.stateUrlValue, { credentials: "same-origin", headers: { "Accept": "application/json" }, signal: this.request.signal })
      if (!response.ok) throw new Error("State unavailable")
      await this.applyScreen(await response.json())
    } catch (error) {
      if (this.element.isConnected) {
        this.availableValue = false
        this.stateMessageValue = "接続を確認しています。しばらくお待ちください。"
        this.update()
      }
    } finally {
      window.clearTimeout(timeout)
      this.polling = false
    }
  }

  async applyScreen(screen, force = false) {
    this.availableValue = screen.available
    this.stateMessageValue = screen.message
    this.update()
    if (!force && screen.history_version === this.historyVersionValue) return
    this.followHistory = force || this.messagesTarget.scrollHeight - this.messagesTarget.scrollTop - this.messagesTarget.clientHeight < 70
    this.previousScrollTop = this.messagesTarget.scrollTop
    this.historyVersionValue = screen.history_version
    try {
      if (this.historyTarget.src) this.historyTarget.reload()
      else this.historyTarget.src = this.historyUrlValue
      await this.historyTarget.loaded
    } catch {
      this.historyVersionValue = ""
    }
  }

  historyLoaded() {
    this.messagesTarget.scrollTop = this.followHistory ? this.messagesTarget.scrollHeight : (this.previousScrollTop || 0)
  }
}
