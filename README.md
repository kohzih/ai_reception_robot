# AI受付ロボット

日本語チャットの用件をCloudflare Clefで分類し、Gazebo上のCRANE+ V2が身振りで案内するアプリです。Railsが入力・履歴・処理状況を管理し、PythonとROS 2を通じてアームを動かします。

| 用件 | 動作 |
|---|---|
| 挨拶 | お辞儀して正面へ戻る |
| 参加受付を探す | 画面右の「受付」を案内して正面へ戻る |
| 講演会場を探す | 画面左の「講演会場」を案内して正面へ戻る |
| 対象外・曖昧な質問、信頼度が低い場合 | 正面でグリッパーを2回開閉し、保留を知らせる |

- [初回準備](#初回準備)
- [起動](#起動)
- [チャットの使い方](#チャットの使い方)
- [仮応答モード](#仮応答モード)
- [異常時の復帰](#異常時の復帰)
- [個別動作の確認](#個別動作の確認)
- [分類評価](#分類評価)
- [仕様と制約](#仕様と制約)

## 初回準備

講義用Dockerイメージ `airobotbook/ros2-desktop-ai-robot-book-humble:latest`を使います。CRANE+ V2のROSパッケージが導入済みの環境を前提とします。

| 項目 | 使用する環境 |
|---|---|
| Webアプリ | Ruby 3.4.11、Rails 8.1.4、SQLite |
| ロボット | ROS 2 Humble、Gazebo、CRANE+ V2 |
| ROS環境 | `/opt/ros/humble/setup.bash`、`/home/ubuntu/airobot_ws/install/setup.bash` |
| プロジェクト | `/home/ubuntu/workspace/ai_reception_robot` |

Rubyとアプリを導入済みなら[起動](#起動)へ進んでください。コンテナの再起動では導入内容は残ります。コンテナを新しく作成する場合は、初回準備から行います。

### 1. プロジェクトを取得する

取得とビルドはコンテナ内の `ubuntu`ユーザーで行います。rootで開いている場合は、`runuser -u ubuntu -- bash`で切り替えてください。

GitHub CLIが未導入なら、[公式のUbuntu用導入手順](https://github.com/cli/cli/blob/trunk/docs/install_linux.md#debian)でセットアップします。認証後、作業フォルダへ取得します。取得済みのフォルダはそのまま使用できます。

```bash
gh auth login --hostname github.com --git-protocol https --web
cd /home/ubuntu/workspace
gh repo clone kohzih/ai_reception_robot
```

### 2. 依存パッケージを導入する

rootまたはsudoで、RubyのビルドとSQLite・Pythonに必要なパッケージを導入します。rootのターミナルでは `sudo`を外してください。

```bash
sudo apt-get update
sudo apt-get install --no-install-recommends -y \
  build-essential curl ca-certificates git pkg-config \
  libssl-dev libyaml-dev zlib1g-dev libreadline-dev libffi-dev libgmp-dev \
  libsqlite3-dev sqlite3 python3-yaml
```

ROS配布元の署名期限エラーで更新できない場合は、[ROS公式の署名移行案内](https://discourse.ros.org/t/ros-signing-key-migration-guide/43937)に従い `ros2-apt-source`へ移行してから再実行します。

### 3. Rubyを導入する

`ubuntu`ユーザーで実行します。RubyはOS付属版と別の場所へ導入し、[公式配布物のSHA256](https://www.ruby-lang.org/en/news/2026/09/23/ruby-3-4-11-released/)を照合します。各コマンドの成功を確認してから次へ進んでください。

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
```

### 4. RailsとDBを準備する

引き続き `ubuntu`ユーザーで実行します。Railsと各Gemの版は `Gemfile.lock`で固定しています。

```bash
cd /home/ubuntu/workspace/ai_reception_robot
source scripts/load_ruby_env.sh
gem install bundler -v 2.6.9 --no-document
bundle install
bin/rails db:prepare
ruby --version
bin/rails --version
```

## 起動

講義コンテナ内で3つのターミナルを用意し、以下の順に起動します。Gazebo・Rails・ワーカーは、それぞれのターミナルで起動したままにしてください。

### 1. Gazeboを起動する（コンテナ内・ターミナルA）

```bash
cd /home/ubuntu/workspace/ai_reception_robot
source scripts/load_runtime_env.sh
DISPLAY=:0 XAUTHORITY=/home/ubuntu/.Xauthority \
  ros2 launch ./simulation/reception.launch.py
```

アームと看板が表示され、コントローラーの起動が完了してから次へ進みます。画面右が「受付」、左が「講演会場」です。

### 2. Railsを起動する（コンテナ内・ターミナルB）

```bash
cd /home/ubuntu/workspace/ai_reception_robot
source scripts/load_runtime_env.sh
bundle install
bin/rails db:prepare
RECEPTION_MODE=live bin/rails server -b 0.0.0.0 -p 3000
```

### 3. 受付処理用ワーカーを起動する（コンテナ内・ターミナルC）

```bash
cd /home/ubuntu/workspace/ai_reception_robot
source scripts/load_runtime_env.sh
bin/robot-worker --interactive
```

Cloudflare Account IDと、Workers AIを実行できるAPIトークンを対話入力します。トークンは非表示で、ファイルには保存しません。

同じシェルの環境変数 `CLOUDFLARE_ACCOUNT_ID`・`CLOUDFLARE_API_TOKEN`へ認証情報を設定済みなら、`--interactive`を省略できます。

### 4. Windowsへの転送を起動する（必要な場合・WSLホスト）

Dockerで3000番を公開していない場合は、コンテナ外のWSLで、共有されたプロジェクトフォルダに移動して実行します。コンテナ名の既定値は `pai_ros2`です。

```bash
python3 scripts/host/forward_rails_port.py
```

転送用ターミナルも開いたままにします。コンテナを再起動した場合は、このスクリプトも起動し直してください。

### 5. ブラウザで確認する

Windowsブラウザで http://localhost:3000 を開き、「AI受付モード」「入力できます」が表示されることを確認します。「こんにちは。」を送信すると、アームがお辞儀して正面へ戻ります。

Gazeboの画面は、講義用デスクトップの http://localhost:6080 から確認できます。

### 停止する

送信した処理の完了を確認してから、ワーカー → Rails → Gazebo → 利用していればWSL転送の順に、各ターミナルで `Ctrl+C`を押します。

## チャットの使い方

| 操作 | 方法 |
|---|---|
| 送信 | 「送信する」またはEnter |
| 改行 | Shift+Enter |
| 日本語の変換確定 | 変換中のEnterでは送信しない |
| 入力文字数 | 200文字以内 |

処理中は追加の送信を受け付けず、画面は約1秒ごとに処理状況を更新します。「指令送信済み」の後に「動作完了を確認しました」が表示されると、次の用件を入力できます。

入力と処理状況はDBに保存し、ブラウザごとに最近50件を表示します。ページを再読み込みしても、履歴と処理状況を引き継ぎます。

## 仮応答モード

APIやロボットを使わずに、画面と応答の表示を確認できます。起動中のRailsとワーカーがある場合は、処理の完了を確認してから両方を停止して切り替えます。

Rails用ターミナル：

```bash
cd /home/ubuntu/workspace/ai_reception_robot
source scripts/load_ruby_env.sh
RECEPTION_MODE=preview bin/rails server -b 0.0.0.0 -p 3000
```

ワーカー用の別ターミナル：

```bash
cd /home/ubuntu/workspace/ai_reception_robot
source scripts/load_ruby_env.sh
RECEPTION_MODE=preview bin/jobs start
```

http://localhost:3000 を開き、仮応答の例を選んで送信します。通常約4秒で応答し、7種類の表示を確認できます。「動作処理の失敗」の例を選ぶと受付停止状態になるため、再開には[復帰手順](#異常時の復帰)が必要です。

実動作へ戻す場合は、Railsとワーカーを停止し、[起動手順](#起動)に従って通常モードのRailsと `bin/robot-worker --interactive`を起動します。

## 異常時の復帰

| 状況 | 受付と再開方法 |
|---|---|
| 待機中のワーカーが停止 | ワーカーを起動すると受付を再開できる |
| API通信や分類処理の失敗 | ロボットへ指令を送らず、再入力を受け付ける |
| 動作失敗、処理中のワーカー停止・再起動 | 受付を停止する。以下の管理コマンドで復帰を確認する |

管理操作は、ワーカーと同じユーザーで行います。未完了の処理は自動で再実行しません。

### 1. 受付とワーカーを停止する

```bash
cd /home/ubuntu/workspace/ai_reception_robot
source scripts/load_runtime_env.sh
bin/rails runner scripts/robot_admin.rb -- pause
```

ワーカーのターミナルで `Ctrl+C`を押して停止します。

### 2. 現在の実行を確認する

```bash
bin/rails runner scripts/robot_admin.rb -- status
```

出力の `state.current_run_id`または `run.id`を確認します。以下の `123`は記載例なので、実際のIDへ置き換えてください。現在の実行IDがない場合は、手順3・4を省略できます。

### 3. 残っているPythonプロセスを終了する

Pythonが残っている場合だけ実行します。PIDと起動時刻が一致する対象を終了しますが、アームの停止は次の手順で確認します。

```bash
bin/rails runner scripts/robot_admin.rb -- stop-process --run-id 123
```

### 4. 停止と正面姿勢を確認する

```bash
bin/rails runner scripts/robot_admin.rb -- recover --run-id 123 --home
```

記録された指令の取消と停止を確認した後、`--home`で正面姿勢とグリッパーの開きへ戻します。成功すると対象の実行を「復帰済み」にし、古いジョブを無効化します。受付停止はこの段階では維持します。

状態が確認できない場合はGazebo一式を停止し、[起動手順](#起動)の1番に従って再起動します。Gazeboを実際に再起動した場合は、上記の `recover`コマンドに `--after-simulator-restart`を追加してください。復帰に失敗した場合は、受付停止を維持して原因を確認します。

### 5. 受付とワーカーを再開する

Gazebo再起動直後は、次の `resume`コマンドにも `--after-simulator-restart`を追加してください。

```bash
bin/rails runner scripts/robot_admin.rb -- resume
```

新しい関節状態・時計・コントローラー・他の指令送信元を確認してから受付を再開します。

成功後、ワーカーを起動します。

```bash
bin/robot-worker --interactive
```

## 個別動作の確認

Gazebo起動後、別のコンテナ内ターミナルで環境を読み込みます。

```bash
cd /home/ubuntu/workspace/ai_reception_robot
source scripts/load_runtime_env.sh
```

次のコマンドを1つずつ実行し、その都度 `completed`と終了コード0を確認してから次へ進みます。

| 動作 | コマンド |
|---|---|
| お辞儀 | `"$ROBOT_PYTHON" scripts/robot/bow.py` |
| 受付案内 | `"$ROBOT_PYTHON" scripts/robot/reception.py` |
| 講演会場案内 | `"$ROBOT_PYTHON" scripts/robot/hall.py` |
| 保留の合図 | `"$ROBOT_PYTHON" scripts/robot/hold.py` |

受付・会場案内は、左右へ約90度向いてお辞儀し、正面へ戻ります。保留の合図は、最初にグリッパーを開いてから閉→開を2回繰り返し、開いた状態で終了します。保留動作の所要時間は通常約16秒です。

標準出力はJSON Linesです。失敗時に `requires_recovery: true`となった場合は、[復帰手順](#異常時の復帰)で確認してから再実行します。

| 調整する項目 | 設定ファイル |
|---|---|
| 角度・時間・停止の判定条件 | [config/robot_motion.yml](config/robot_motion.yml) |
| 看板の位置 | [simulation/reception.sdf](simulation/reception.sdf) |
| 固定カメラ | [simulation/gui.config](simulation/gui.config) |

アームの移動はシミュレーション時間で2秒、お辞儀は約20度、保持は実時間で0.5秒です。保留時のグリッパー移動はシミュレーション時間で1.5秒、保持は実時間で0.4秒です。マウスで視点を変えた場合は、保存済みの設定でGazeboを起動し直すと元の視点に戻ります。

## 分類評価

Clefの分類結果と動作の選択を確認するコマンドです。ロボットへ指令は送らないため、Gazeboの起動は不要です。ワーカーと同じCloudflare Account ID・APIトークンを対話入力します。

コンテナ内でRuby環境を読み込みます。

```bash
cd /home/ubuntu/workspace/ai_reception_robot
source scripts/load_ruby_env.sh
```

### 修正前後の基準を比較する

同じ15文を2つの基準で比較し、計30回APIを呼びます。

```bash
bin/rails runner scripts/verify_clef.rb -- --interactive
```

### 修正後の基準だけを確認する

15回APIを呼びます。

```bash
bin/rails runner scripts/verify_clef.rb -- --interactive --variant revised
```

### 別の入力20文で評価する

調整用の15文とは別の20文を使い、修正後の基準で20回APIを呼びます。

```bash
bin/rails runner scripts/verify_clef.rb -- --interactive --dataset holdout
```

各実行の結果は `docs/evaluation/`内の新しいフォルダへ保存します。APIエラーが発生した場合は処理を止め、途中結果と未実行の入力を残します。

| ファイル | 内容 |
|---|---|
| `metadata.json` | モデル、評価入力、分類基準・入力のハッシュ、閾値 |
| `results.jsonl` | 入力、期待分類、実分類、確率、信頼度、選択動作・定型文、応答時間、入力トークン数 |
| `summary.json` | 分類・動作選択の正解率、誤案内の選択、不要な保留、応答時間の集計 |

## 仕様と制約

- 分類は `greeting`・`reception`・`hall`・`unknown`の4種類です。`unknown`または信頼度0.5未満なら保留を選び、それ以外は分類に対応する固定のPythonスクリプトを実行します。
- 分類基準は [config/intent_criteria.json](config/intent_criteria.json)にあります。[Clefの公式仕様](https://developers.cloudflare.com/workers-ai/models/clef/)も参照できます。
- 判定は1メッセージごとに行います。前の会話を踏まえた対話や、複数の案内先への同時案内は行いません。
- 信頼度0.5は動作選択の閾値であり、正解確率を保証する値ではありません。
- 動作完了は、Pythonの全段階の成功イベントと正常終了を確認してから表示します。
- API通信の上限は、接続5秒・読取り20秒・書込み5秒・リクエスト全体60秒です。
- 対象はGazebo内のアームです。実機・音声入力・来訪者の検出は含みません。
