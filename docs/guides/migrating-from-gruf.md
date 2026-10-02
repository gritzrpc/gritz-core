# GrufからGritzへの移行

既存Controllerの継承先を`Gritz::Compat::Gruf::Controller`に変え、まず`workers 0`でRPCを確認する。
互換レイヤはGruf 2.22.0のController・Interceptor APIのうち、下表の範囲を扱う。
Gruf本体への実行時依存や、グローバルな`Gruf`定数の置き換えは行わない。

| 既存コード | 移行後 |
| --- | --- |
| `Gruf::Controllers::Base`の継承 | `Gritz::Compat::Gruf::Controller`を継承 |
| `bind Service` | 同じ定義を維持し、設定でControllerを登録 |
| `request.message` / `request.messages` | Unaryの値、client streamingの`message.call { ... }`、Enumerableによるbidiを維持 |
| server/bidiの返却Enumerator | 互換Controller内で列挙して送信。Middlewareも列挙終了まで有効 |
| `request.metadata` / `active_call.metadata` | 受信メタデータを参照 |
| `request.context` | RPC内で共有。`[]`、`[]=`、`fetch`、`key?`、`merge!`はSymbol/Stringキーを共通化 |
| `fail!(code, app_code, message, metadata)` | 引数を維持。gRPC statusと`error-internal-bin`のJSONを返す |
| `add_field_error` / `has_field_errors?` / `set_debug_info` | アプリケーションが明示したエラー情報を維持 |
| `ServerInterceptor#call`の`yield` | `Gritz::Compat::Gruf.interceptor`でMiddlewareへ接続 |

`request.context`はActiveSupportの`HashWithIndifferentAccess`全体を再実装してはいない。
独自のserializer、Grufのグローバル設定・logger、Controllerの独自`call`/`process_action`、C-core固有の`active_call`操作は個別に移す。
トレーラ中のアプリケーションコードを読む既存クライアントは維持できるが、Gritzの標準リッチエラー形式とは別のJSON形式である。

## Controllerと起動設定を移す

アプリケーションのGemfileへ`gritz`を追加する。Railsの起動・autoload・Executor連携には`gritz-rails`も追加する。
Controllerでは継承先だけを変更できる。

```ruby
require "gritz/compat/gruf"

class ProductsController < Gritz::Compat::Gruf::Controller
  bind Rpc::Products::Service

  def get_product
    product = Product.find(request.message.id)
    Rpc::GetProductResp.new(product: product.to_proto)
  rescue ActiveRecord::RecordNotFound
    fail!(:not_found, :product_not_found, "Product not found")
  end
end
```

`config/gritz.rb`で生成済みprotobufとControllerを読み込み、`register_controller ProductsController`を設定する。
Railsのautoloadを使う場合はRails統合の起動設定に従う。Grufの`bind`が行うグローバルサービス登録は引き継がない。
最初は次のようなシングルプロセス設定にする。

```ruby
workers 0
bind "0.0.0.0:9001"
register_controller ProductsController
```

既存のリクエストを実際に送り、レスポンス、順序、ステータス、エラートレーラを比較してからfork対応へ進む。
Grufの3番目の`fail!`引数はメッセージである。Gritz標準Controllerの`fail!(code, message, ...)`へ置き換える際は、位置引数をそのまま移さない。

## Interceptorを明示的に接続する

独自Interceptorの継承先を`Gritz::Compat::Gruf::ServerInterceptor`へ変更する。
`initialize(request, error, options = {})`と`call`内の`yield`を維持し、設定でアダプタを登録する。

```ruby
class TokenAuthentication < Gritz::Compat::Gruf::ServerInterceptor
  def call
    fail!(:unauthenticated, :invalid_token, "Invalid token") unless request.metadata["token"] == options.fetch(:token)
    yield
  end
end

middleware do |stack|
  stack.use(Gritz::Compat::Gruf.interceptor(TokenAuthentication), token: ENV.fetch("RPC_TOKEN"))
end
```

登録順に外側から実行され、同じRPCのRequest・エラー状態を共有する。
InterceptorがUnaryリクエストを先に読んでも、互換Controllerと標準`Gritz::Controller`のどちらでも二重に消費・計上しない。
Gruf組み込みInterceptorは自動では登録されない。必要な実装を確認して自分のアプリケーションへ移すか、Gritz/Railsの標準機能へ置き換える。
認証設定を抜いたまま起動せず、不正な認証情報を拒否するテストも移す。

## 静的な設定だけを変換する

`gritz-migrate-gruf`は入力を実行せず、Ruby標準のRipperで構文を解析する。
単一の`Gruf.configure do |c| ... end`または`Gruf.configure { |c| ... }`に含まれる、次のリテラル代入を変換する。

| Gruf設定 | Gritz設定 |
| --- | --- |
| `server_binding_url` | `bind` |
| `rpc_server_options[:pool_size]` | `threads` |
| `rpc_server_options[:max_waiting_requests]` | `max_waiting_requests` |
| `use_ssl = true`、`ssl_crt_file`、`ssl_key_file` | `tls({ cert: ..., key: ... })` |
| `server_args`の`grpc.max_receive_message_length` / `grpc.max_send_message_length` / `grpc.max_metadata_size` | 対応するメッセージ・メタデータ上限 |
| `grpc.max_connection_age_ms` / `grpc.max_connection_age_grace_ms` / `grpc.keepalive_time_ms` | 対応する秒単位の設定 |

`rpc_server_options`はHash全体への代入を使う。たとえば`c.rpc_server_options = { pool_size: 8 }`である。
出力には`workers 0`とController登録の確認コメントが入る。
明示されなかった設定はGritzの既定値になるため、元のGrufの既定値や環境変数による設定も確認する。
TLSファイルの内容は読み込まない。生成後にファイルの存在・権限と、証明書・秘密鍵の対応を確認する。

```sh
bundle exec gritz-migrate-gruf gruf-literals.rb
bundle exec gritz-migrate-gruf gruf-literals.rb --output config/gritz.rb
```

指定先が存在すれば上書きを拒否する。未対応の項目や式があれば終了コード1で停止し、設定を黙って省略しない。
`require`などblock外の実行コード、`ENV.fetch`、メソッド呼び出し、文字列の補間・エスケープ、Proc、条件分岐、Hashの展開、重複設定は対象外である。
`default_client_host`や認証・serializer・Interceptor・`poll_period`などは手作業で移す。
これらを含む実際のinitializerは変換エラーになる。元の設定を確認して静的な項目を専用ファイルへ抜き出し、残る項目を移行先で設定する。

## forkを有効にする前に比較する

1. 4種類のRPCの値・ストリーム順序を、既存クライアントで比較する。
2. 認証の成功・拒否、NotFound、入力エラー、アプリケーションコードのトレーラを比較する。
3. RailsのDB接続、外向きクライアント、ThreadをMasterで作っていないことを確認する。protobufのロードとクライアント定義はMasterで行える。
4. `bundle exec gritz check -C config/gritz.rb`を実行し、fork前に作られたリソースをWorker側の初期化へ移す。
5. 固定ポートと`workers N`に変更し、起動、終了、Worker交換時の挙動を確認する。

確認後、互換APIを必要な箇所からGritz標準Controller・Middlewareへ置き換える。
明示した`set_debug_info`は互換JSONに含まれるため、外部に返してよい情報かも確認する。

## 公式サンプルで確認した範囲

[Gruf READMEのDemo Rails App](https://github.com/bigcommerce/gruf#demo-rails-app)が紹介する[bigcommerce/gruf-demo](https://github.com/bigcommerce/gruf-demo)を使った。
Gruf 2.22.0とDemoの固定SHA、元ファイルごとのSHA256、MITライセンスは[Nativeの検証fixture](https://github.com/gritzrpc/gritz-native/tree/main/spec/integration/gruf/fixtures/upstream)に保存している。
ProductsControllerは継承先1行だけを変更し、4種類の実RPC、NotFound、Basic認証、ActiveRecordモデルのvalidationを元のGrufと比較する。
比較ではSQLiteを使い、元アプリケーション全体のRails起動・MySQL・画面までは扱わない。
この検証を自分のアプリケーションの移行テストへ追加し、固有のInterceptorやエラー形式も確認する。
