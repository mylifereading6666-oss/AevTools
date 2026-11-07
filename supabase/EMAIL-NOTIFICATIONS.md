# AevTools サポート返信・メール通知の設定

## 1. 返信機能

GitHub Pagesの最新HTMLでは、ユーザーの「送信したリクエスト・返信」と管理者ダッシュボードに「会話・返信を表示」ボタンを追加しています。

- 問い合わせ本人：返信を送信できます
- 永久管理者：問い合わせに返信できます
- 返信すると問い合わせ状態は「受付中」に戻ります

ページが古い場合は、ブラウザーで再読み込みしてください。Android Chromeではページを開き直すか、再読み込みを行ってください。

## 2. メール通知の仕組み

メール通知はブラウザーから直接送信せず、Supabase Edge FunctionとResendを利用します。

- 新しい問い合わせ：管理者メールへ通知
- ユーザーからの返信：管理者メールへ通知
- 管理者からの返信：問い合わせユーザーの登録メールへ通知

ResendのAPIキーやService Role Keyは、公開HTMLには絶対に書きません。

## 3. Resendの準備

1. Resend（https://resend.com/）でアカウントを作成します。
2. 送信元に使うメールドメインを登録・認証します。
3. Resend API Keyを作成します。
4. メール送信元は認証済みドメインのアドレスにします（例：AevTools <support@your-verified-domain>）。

## 4. Supabase Edge Functionの設定

Supabase Dashboardで対象プロジェクトを開きます。

1. Edge Functions を開きます。
2. `support-email-notify` という名前で関数を作成します。
3. このリポジトリの `supabase/functions/support-email-notify/index.ts` の内容を関数に貼り付けてDeployします。

関数のSecrets（環境変数）に次の3つを設定します。

| Secret名 | 値 |
|---|---|
| `RESEND_API_KEY` | Resendで作成したAPI Key |
| `ADMIN_EMAIL` | 管理者が通知を受け取るメールアドレス |
| `EMAIL_FROM` | Resendで認証済みの送信元アドレス（例：`AevTools Support <support@your-verified-domain>`） |

`SUPABASE_URL`、`SUPABASE_SERVICE_ROLE_KEY`、`SUPABASE_ANON_KEY` はSupabase Edge Functionsの環境で利用されます。もし環境に自動設定されていない場合は、SupabaseのProject URL、Publishable/anon key、Service Role KeyをEdge Function Secretsに設定してください。Service Role Keyはこの関数のSecretsにのみ保存し、HTMLやGitHub公開ファイルには絶対に書かないでください。

## 5. メール通知のテスト

1. AevToolsでログインします。
2. サポートリクエストを送信します。
3. 管理者メールに通知が届くことを確認します。
4. 管理者から返信し、問い合わせユーザーの登録メールに通知が届くことを確認します。

メール送信が失敗しても、問い合わせや返信自体はSupabaseに保存されます。画面にはメール通知設定が未完了である旨が表示されます。

## 関連リンク

- AevTools：https://mylifereading6666-oss.github.io/AevTools/
- Supabase Edge Functions：https://supabase.com/dashboard/project/vuqbbwdojwmtehgsyfaq/functions
- Resend：https://resend.com/