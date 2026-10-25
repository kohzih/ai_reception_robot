# AI受付ロボット

Rails・Cloudflare Clef・ROS 2・CRANE+ V2を組み合わせ、来訪者の日本語入力に応じて身振りで案内するアプリです。チャットからClefで意図を分類し、シミュレータのアームがお辞儀・受付案内・講演会場案内・保留の合図を行います。

Ruby **3.4.11**、Rails **8.1.4**、SQLiteを使用します。開発環境は講義用Dockerイメージ `airobotbook/ros2-desktop-ai-robot-book-humble:latest`です。

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

Gazeboも起動した状態で、ブラウザから http://localhost:3000 を開きます。画面の入力例を選ぶか、200文字以内でメッセージを入力し、「送信する」を押します。案内の定型文、指令送信、動作完了を順番に表示します。動作完了は、Pythonの全段階の成功イベントと正常終了の両方を確認してから表示します。

入力と処理状況はDBへ保存し、このブラウザの最近50件を表示します。再読み込み後も履歴と処理状況を確認でき、別のブラウザとは履歴を分けます。処理中は全画面からの追加受付を停止し、画面は約1秒ごとに状態を更新します。

ワーカー停止中は受付できません。APIエラーではロボットへ指令を送らず、再入力を受け付けます。動作失敗や処理中のワーカー停止・再起動では、未完了の処理を自動で再実行せず、確認が済むまで受付を停止します。現在は画面からの復旧操作を実装していません。

画面表示だけを確認する場合は、Railsを起動するシェルで `export RECEPTION_MODE=preview` を設定し、ワーカーは `bin/jobs start`で起動します。約4秒の仮処理で7種類の応答例を確認でき、APIやロボットは呼び出しません。実動作へ戻すときは `RECEPTION_MODE=live`でRailsを再起動します。モードはサーバーが決定します。

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

分類は `greeting`・`reception`・`hall`・`unknown` の4種類です。`unknown`または信頼度が0.5未満の場合は保留の合図を選び、0.5以上では分類に対応する動作を選びます。通信エラーや不正応答の場合は動作を選びません。検証コマンドは分類と動作の選択結果を表示し、ロボットへの指令は送りません。通信の上限は接続5秒・読取り20秒・書込み5秒・リクエスト全体60秒です。分類基準は `config/intent_criteria.json` にあります。[Clef公式仕様](https://developers.cloudflare.com/workers-ai/models/clef/)

Docker上で3000番を公開していない場合は、コンテナ外のWSLで共有されたプロジェクトフォルダを開き、次を実行します。コンテナ名の既定値は `pai_ros2`です。

```bash
python3 scripts/host/forward_rails_port.py
```

Rails・受付処理用ワーカー・転送スクリプトを起動したまま、Windowsブラウザで http://localhost:3000 を開きます。停止はそれぞれ `Ctrl+C`。コンテナ再起動後は転送スクリプトも起動し直してください。

`.env.example`は設定名の一覧で、自動読み込みは行いません。実際のAPIトークン・`config/master.key`・DB・ログ・録画はGitへ登録しません。
