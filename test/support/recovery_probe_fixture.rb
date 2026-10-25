require "json"
variant, nonce = ARGV
lock = IO.for_fd(3)
raise "Missing inherited lock" unless lock.stat.file?
abort "Credentials inherited" if ENV["CLOUDFLARE_API_TOKEN"] || ENV["CLOUDFLARE_ACCOUNT_ID"]
if variant == "hang"
  Signal.trap("TERM", "IGNORE")
  loop { sleep 0.02 }
end
if variant == "flood"
  puts "x" * 70_000
  exit
end
nonce = "other" if variant == "wrong_nonce"
puts JSON.generate(event: "recovery_verified", nonce: nonce, ready: true, front: true, stopped: true)
exit(variant == "nonzero" ? 1 : 0)
