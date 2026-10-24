# AI受付ロボット

Rails・Cloudflare Clef・ROS 2・CRANE+ V2を組み合わせ、来訪者の日本語入力に応じて身振りで案内するアプリです。現在はRailsのひな形と、お辞儀・受付案内・講演会場案内・保留の合図の単独動作を実装しています。

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

Docker上で3000番を公開していない場合は、コンテナ外のWSLで共有されたプロジェクトフォルダを開き、次を実行します。コンテナ名の既定値は `pai_ros2`です。

```bash
python3 scripts/host/forward_rails_port.py
```

Railsと転送スクリプトを起動したまま、Windowsブラウザで http://localhost:3000 を開きます。停止はそれぞれ `Ctrl+C`。コンテナ再起動後は転送スクリプトも起動し直してください。

`.env.example`は設定名の一覧で、自動読み込みは行いません。実際のAPIトークン・`config/master.key`・DB・ログ・録画はGitへ登録しません。
