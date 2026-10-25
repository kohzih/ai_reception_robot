class ReceptionMode
  def self.preview?
    Rails.configuration.x.reception_mode == "preview"
  end
end
