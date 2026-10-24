# AI受付ロボット

Rails・Cloudflare Clef・ROS 2・CRANE+ V2を組み合わせ、来訪者の日本語入力に応じて身振りで案内するアプリです。現在はRailsのひな形を作成した段階です。

Ruby **3.4.11**、Rails **8.1.4**、SQLiteを使用します。開発環境は講義用Dockerイメージ `airobotbook/ros2-desktop-ai-robot-book-humble:latest`です。

コンテナ内のプロジェクトフォルダで起動します。

```bash
source scripts/load_runtime_env.sh
bundle install
bin/rails db:prepare
bin/rails server -b 0.0.0.0 -p 3000
```

シミュレータは、別のコンテナ内ターミナルで起動します。

```bash
source scripts/load_runtime_env.sh
DISPLAY=:0 XAUTHORITY=/home/ubuntu/.Xauthority \
  ros2 launch crane_plus_gazebo crane_plus_with_table.launch.py
```

Gazebo起動後、別のコンテナ内ターミナルでお辞儀を実行できます。

```bash
source scripts/load_runtime_env.sh
"$ROBOT_PYTHON" scripts/robot/bow.py
```

標準出力はJSON Linesです。`completed`と終了コード0で正常完了を確認できます。`requires_recovery: true`で失敗した場合は、停止状態と正面への復帰を確認するまで再実行を受け付けません。

Docker上で3000番を公開していない場合は、コンテナ外のWSLで共有されたプロジェクトフォルダを開き、次を実行します。コンテナ名の既定値は `pai_ros2`です。

```bash
python3 scripts/host/forward_rails_port.py
```

Railsと転送スクリプトを起動したまま、Windowsブラウザで http://localhost:3000 を開きます。停止はそれぞれ `Ctrl+C`。コンテナ再起動後は転送スクリプトも起動し直してください。

`.env.example`は設定名の一覧で、自動読み込みは行いません。実際のAPIトークン・`config/master.key`・DB・ログ・録画はGitへ登録しません。
