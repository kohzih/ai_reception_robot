# AI受付ロボット

Rails・Cloudflare Clef・ROS 2・CRANE+ V2を組み合わせ、来訪者の日本語入力に応じて身振りで案内するアプリです。チャットからClefで意図を分類し、シミュレータのアームがお辞儀・受付案内・講演会場案内・保留の合図を行います。

Ruby **3.4.11**、Rails **8.1.4**、SQLiteを使用します。開発環境は講義用Dockerイメージ `airobotbook/ros2-desktop-ai-robot-book-humble:latest`です。

## 初回準備

講義コンテナ内の `/opt/ros/humble/setup.bash` と `/home/ubuntu/airobot_ws/install/setup.bash`、CRANE+ V2のROSパッケージを利用します。汎用のRubyイメージだけではシミュレータは起動できません。Rubyとアプリを導入済みなら「起動」へ進んでください。コンテナの再起動では導入内容は残り、新しいコンテナを作成した場合はこの準備が必要です。

取得とビルドはコンテナ内の `ubuntu`ユーザーで行います。rootで開いている場合は `runuser -u ubuntu -- bash`で切り替えます。GitHub CLIが未導入なら、[公式のUbuntu用導入手順](https://github.com/cli/cli/blob/trunk/docs/install_linux.md#debian)でセットアップします。認証後、コンテナ内の作業フォルダへ取得します。既にフォルダがある場合は再取得しません。

```bash
gh auth login --hostname github.com --git-protocol https --web
cd /home/ubuntu/workspace
gh repo clone kohzih/ai_reception_robot
```

Rubyのビルド依存をrootまたはsudoで導入します。

```bash
sudo apt-get update
sudo apt-get install --no-install-recommends -y \
  build-essential curl ca-certificates git pkg-config \
  libssl-dev libyaml-dev zlib1g-dev libreadline-dev libffi-dev libgmp-dev \
  libsqlite3-dev sqlite3 python3-yaml
```

rootのターミナルでは `sudo`を外します。ROS配布元の署名期限エラーで更新できない場合は、[ROS公式の署名移行案内](https://discourse.ros.org/t/ros-signing-key-migration-guide/43937)に従い `ros2-apt-source`へ移行してから再実行します。各コマンドの成功を確認してから次へ進みます。

以下も `ubuntu`ユーザーで実行します。RubyはOS付属版と分け、[公式3.4.11配布物のSHA256](https://www.ruby-lang.org/en/news/2026/09/23/ruby-3-4-11-released/)を照合します。

```bash
mkdir -p /home/ubuntu/.cache/ai-reception-ruby /home/ubuntu/.local
cd /home/ubuntu/.cache/ai-reception-ruby
curl -fL -o ruby-3.4.11.tar.gz \
  https://cache.ruby-lang.org/pub/ruby/3.4/ruby-3.4.11.tar.gz
printf '%s\n' '5c22be44524312b3d433d68739bcc530633b1da5ef8ba0afa0a37680da17d3de  ruby-3.4.11.tar.gz' | sha256sum -c -
tar -xzf ruby-3.4.11.tar.gz
cd ruby-3.4.11
./configure --prefix=/home/ubuntu/.local/ruby-3.4.11 --disable-install-doc --disable-yjit
make -j2
make install
cd /home/ubuntu/workspace/ai_reception_robot
source scripts/load_ruby_env.sh
gem install bundler -v 2.6.9 --no-document
bundle install
bin/rails db:prepare
ruby --version
bin/rails --version
```

Railsと各Gemの版は `Gemfile.lock`で固定しています。認証情報はリポジトリへ保存せず、下記のワーカー起動時に対話入力します。

## 起動

コンテナ内のプロジェクトフォルダで起動します。

```bash
source scripts/load_runtime_env.sh
bundle install
bin/rails db:prepare
bin/rails server -b 0.0.0.0 -p 3000
```

別のコンテナ内ターミナルで、受付処理用のワーカーも起動します。

```bash
source scripts/load_runtime_env.sh
bin/robot-worker --interactive
```

Cloudflare Account IDとWorkers AI用APIトークンを入力します。トークンは非表示で受け取り、ファイルやコマンド引数へ保存しません。認証情報を同じシェルの環境変数へ設定済みなら `--interactive`を省略できます。認証情報はワーカーで使用し、ロボット用Pythonには渡しません。

Gazeboも起動した状態で、ブラウザから http://localhost:3000 を開きます。画面の入力例を選ぶか、200文字以内でメッセージを入力し、「送信する」またはEnterで送信します。Shift+Enterで改行できます。日本語入力の変換確定では送信しません。案内の定型文、指令送信、動作完了を順番に表示します。動作完了は、Pythonの全段階の成功イベントと正常終了の両方を確認してから表示します。

入力と処理状況はDBへ保存し、このブラウザの最近50件を表示します。再読み込み後も履歴と処理状況を確認でき、別のブラウザとは履歴を分けます。処理中は全画面からの追加受付を停止し、画面は約1秒ごとに状態を更新します。

ワーカー停止中は受付できません。APIエラーではロボットへ指令を送らず、再入力を受け付けます。動作失敗や処理中のワーカー停止・再起動では、未完了の処理を自動で再実行せず、確認が済むまで受付を停止します。復帰操作はコンテナ内の管理コマンドから行います。

画面表示だけを確認する場合は、Railsを起動するシェルで `export RECEPTION_MODE=preview` を設定し、ワーカーは `bin/jobs start`で起動します。約4秒の仮処理で7種類の応答例を確認でき、APIやロボットは呼び出しません。実動作へ戻すときは `RECEPTION_MODE=live`でRailsを再起動します。モードはサーバーが決定します。

異常後の復帰は、ワーカーと同じユーザーで共通環境を読み込み、受付を停止してから行います。

```bash
source scripts/load_runtime_env.sh
bin/rails runner scripts/robot_admin.rb -- pause
```

ワーカーのターミナルで `Ctrl+C`を押して停止し、現在の実行ID・指令・Pythonプロセスを確認します。

```bash
bin/rails runner scripts/robot_admin.rb -- status
```

Pythonが残っている場合は、表示された実行IDを指定します。PIDと起動時刻が一致するプロセスだけを終了します。プロセス終了だけではアーム停止として扱いません。

```bash
bin/rails runner scripts/robot_admin.rb -- stop-process --run-id 123
```

同じ実行IDで復帰を確認します。`--home`は、記録した指令の取消と停止を確認した後に、正面姿勢とグリッパーの開きへ戻す明示操作です。

```bash
bin/rails runner scripts/robot_admin.rb -- recover --run-id 123 --home
```

状態が不明な場合はGazebo一式を停止し、下記の起動方法で再起動してから、`recover`に `--after-simulator-restart`も付けます。新しい関節状態・時計・コントローラー・他の指令送信元を確認し、古いジョブを無効化してから復帰します。失敗時は受付停止を維持します。

最後に受付を再開し、実API用ワーカーを起動します。Gazebo再起動直後は `resume`にも `--after-simulator-restart`を付けます。現在の実行IDがない場合は `recover`と `stop-process`を省略できます。

```bash
bin/rails runner scripts/robot_admin.rb -- resume
bin/robot-worker --interactive
```

シミュレータは、別のコンテナ内ターミナルで起動します。

```bash
source scripts/load_runtime_env.sh
DISPLAY=:0 XAUTHORITY=/home/ubuntu/.Xauthority \
  ros2 launch ./simulation/reception.launch.py
```

この起動設定は講義用の机・アームに日本語の看板を加えます。固定カメラから見て右が「受付」、左が「講演会場」です。看板の位置は `simulation/reception.sdf`、カメラは `simulation/gui.config` に保存されています。マウスで視点を変えた場合は、この設定でシミュレータを起動し直すと元の視点に戻ります。

Gazebo起動後、別のコンテナ内ターミナルで共通環境を読み込みます。

```bash
source scripts/load_runtime_env.sh
```

お辞儀：

```bash
"$ROBOT_PYTHON" scripts/robot/bow.py
```

受付案内（右へ90度回転 → お辞儀 → アームを起こす → 正面へ戻る）：

```bash
"$ROBOT_PYTHON" scripts/robot/reception.py
```

講演会場案内（左へ90度回転 → お辞儀 → アームを起こす → 正面へ戻る）：

```bash
"$ROBOT_PYTHON" scripts/robot/hall.py
```

保留の合図（正面の直立姿勢で、閉じる → 開くを2回）：

```bash
"$ROBOT_PYTHON" scripts/robot/hold.py
```

保留の合図は、最初にグリッパーを開いた状態へそろえ、2回の開閉後も開いた状態で終了します。所要時間は約16秒です。

各コマンドは1つずつ実行し、正常終了を確認してから次を実行します。アームの移動はシミュレーション時間で2秒、お辞儀は約20度、保持は実時間で0.5秒です。保留時のグリッパー移動はシミュレーション時間で1.5秒、各移動後の保持は実時間で0.4秒です。角度と時間は `config/robot_motion.yml` に保存されています。

標準出力はJSON Linesです。`completed`と終了コード0で正常完了を確認できます。`requires_recovery: true`で失敗した場合は、停止状態と正面への復帰を確認するまで再実行を受け付けません。

Clefの分類を確認するには、コンテナ内で次を実行します。

```bash
source scripts/load_ruby_env.sh
bin/rails runner scripts/verify_clef.rb -- --interactive
```

Cloudflare Account IDとWorkers AI用APIトークンを入力します。トークンは非表示で受け取り、認証情報は保存しません。環境変数 `CLOUDFLARE_ACCOUNT_ID`・`CLOUDFLARE_API_TOKEN`を同じシェルで設定した場合は、`--interactive`を省略できます。必要なAPI権限はWorkers AIの実行権限です。

既定では同じ15文を修正前・修正後の分類基準で比較し、計30回APIを呼び出します。`--variant revised`で修正後だけを確認できます。入力、分類、確率、信頼度、選択した動作・定型文、応答時間を `docs/evaluation/`の新しいフォルダへ保存します。実測記録はローカルのGit管理外です。APIエラー時は比較を止め、途中結果と未実行の入力を残します。

分類基準を固定した後の別入力20文は、`bin/rails runner scripts/verify_clef.rb -- --interactive --dataset holdout`で評価します。既定では修正後の基準だけを使用し、20回APIを呼びます。入力と分類基準のハッシュ、分類正解率、最終動作の一致率、誤った方向案内、不要な保留、応答時間を記録します。ロボットは動かしません。

分類は `greeting`・`reception`・`hall`・`unknown` の4種類です。`unknown`または信頼度が0.5未満の場合は保留の合図を選び、0.5以上では分類に対応する動作を選びます。通信エラーや不正応答の場合は動作を選びません。検証コマンドは分類と動作の選択結果を表示し、ロボットへの指令は送りません。通信の上限は接続5秒・読取り20秒・書込み5秒・リクエスト全体60秒です。分類基準は `config/intent_criteria.json` にあります。[Clef公式仕様](https://developers.cloudflare.com/workers-ai/models/clef/)

判定は入力した1メッセージごとに行い、前の会話を踏まえた対話や複数の案内先への同時案内は行いません。信頼度0.5は動作を選ぶ閾値で、正解確率を保証する値ではありません。対象はGazebo内のアームで、実機・音声入力・来訪者の検出は含みません。

Docker上で3000番を公開していない場合は、コンテナ外のWSLで共有されたプロジェクトフォルダを開き、次を実行します。コンテナ名の既定値は `pai_ros2`です。

```bash
python3 scripts/host/forward_rails_port.py
```

Rails・受付処理用ワーカー・転送スクリプトを起動したまま、Windowsブラウザで http://localhost:3000 を開きます。停止はそれぞれ `Ctrl+C`。コンテナ再起動後は転送スクリプトも起動し直してください。

`.env.example`は設定名の一覧で、自動読み込みは行いません。実際のAPIトークン・`config/master.key`・DB・ログ・録画はGitへ登録しません。
