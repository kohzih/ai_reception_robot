import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["input", "counter", "submit", "status", "messages", "scenario", "errors"]
  static values = { maxCharacters: Number }

  connect() {
    this.busy = false
    this.deliveryUncertain = false
    this.update()
    this.messagesTarget.scrollTop = this.messagesTarget.scrollHeight
    if (this.hasErrorsTarget) this.inputTarget.focus()
  }

  update() {
    const length = Array.from(this.inputTarget.value).length
    const blank = this.inputTarget.value.trim().length === 0
    const tooLong = length > this.maxCharactersValue
    this.counterTarget.textContent = `${length} / ${this.maxCharactersValue}`
    this.counterTarget.classList.toggle("over-limit", tooLong)
    this.inputTarget.setCustomValidity(blank ? "メッセージを入力してください。" : (tooLong ? "200文字以内で入力してください。" : ""))
    this.submitTarget.disabled = blank || tooLong || this.busy || this.deliveryUncertain
    this.inputTarget.readOnly = this.busy
    this.scenarioTarget.disabled = this.busy
    this.statusTarget.textContent = this.deliveryUncertain ? "送信結果を確認できません。再読み込みしてください。" : (this.busy ? "仮応答を確認中…" : "入力できます")
  }

  example({ params }) {
    if (this.busy || this.deliveryUncertain) return
    this.inputTarget.value = params.text
    this.scenarioTarget.value = params.scenario
    this.update()
    this.inputTarget.focus()
  }

  submitting() {
    this.busy = true
    this.update()
  }

  submitted(event) {
    this.busy = false
    this.deliveryUncertain = Boolean(event.detail.error)
    this.update()
  }
}
