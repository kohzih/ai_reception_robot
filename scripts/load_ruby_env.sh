# Source this file in the lecture container before using Ruby or Rails.
# Example: source /home/ubuntu/workspace/ai_reception_robot/scripts/load_ruby_env.sh

PAI_RUBY_BIN=/home/ubuntu/.local/ruby-3.4.11/bin

if [ ! -x "$PAI_RUBY_BIN/ruby" ]; then
    printf 'Ruby 3.4.11 is not installed at %s\n' "$PAI_RUBY_BIN" >&2
    unset PAI_RUBY_BIN
    return 1
fi

case "$PATH" in
    "$PAI_RUBY_BIN"|"$PAI_RUBY_BIN":*) ;;
    *) PATH="$PAI_RUBY_BIN:$PATH" ;;
esac
export PATH
unset PAI_RUBY_BIN
