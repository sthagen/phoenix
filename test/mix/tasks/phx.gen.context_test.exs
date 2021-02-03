Code.require_file "../../../installer/test/mix_helper.exs", __DIR__

defmodule Phoenix.DupContext do
end

defmodule Mix.Tasks.Phx.Gen.ContextTest do
  use ExUnit.Case
  import MixHelper
  alias Mix.Tasks.Phx.Gen
  alias Mix.Phoenix.{Context, Schema}

  setup do
    Mix.Task.clear()
    :ok
  end

  test "new context", config do
    in_tmp_project config.test, fn ->
      schema = Schema.new("Blog.Post", "posts", [], [])
      context = Context.new("Blog", schema, [])

      assert %Context{
        alias: Blog,
        base_module: Phoenix,
        basename: "blog",
        module: Phoenix.Blog,
        web_module: PhoenixWeb,
        schema: %Mix.Phoenix.Schema{
          alias: Post,
          human_plural: "Posts",
          human_singular: "Post",
          module: Phoenix.Blog.Post,
          plural: "posts",
          singular: "post"
        }} = context

      assert String.ends_with?(context.dir, "lib/phoenix/blog")
      assert String.ends_with?(context.file, "lib/phoenix/blog.ex")
      assert String.ends_with?(context.test_file, "test/phoenix/blog_test.exs")
      assert String.ends_with?(context.test_fixtures_file, "test/support/fixtures/blog_fixtures.ex")
      assert String.ends_with?(context.schema.file, "lib/phoenix/blog/post.ex")
    end
  end

  test "new nested context", config do
    in_tmp_project config.test, fn ->
      schema = Schema.new("Site.Blog.Post", "posts", [], [])
      context = Context.new("Site.Blog", schema, [])

      assert %Context{
        alias: Blog,
        base_module: Phoenix,
        basename: "blog",
        module: Phoenix.Site.Blog,
        web_module: PhoenixWeb,
        schema: %Mix.Phoenix.Schema{
          alias: Post,
          human_plural: "Posts",
          human_singular: "Post",
          module: Phoenix.Site.Blog.Post,
          plural: "posts",
          singular: "post"
        }} = context

      assert String.ends_with?(context.dir, "lib/phoenix/site/blog")
      assert String.ends_with?(context.file, "lib/phoenix/site/blog.ex")
      assert String.ends_with?(context.test_file, "test/phoenix/site/blog_test.exs")
      assert String.ends_with?(context.test_fixtures_file, "test/support/fixtures/site/blog_fixtures.ex")
      assert String.ends_with?(context.schema.file, "lib/phoenix/site/blog/post.ex")
    end
  end

  test "new existing context", config do
    in_tmp_project config.test, fn ->
      File.mkdir_p!("lib/phoenix/blog")
      File.write!("lib/phoenix/blog.ex", """
      defmodule Phoenix.Blog do
      end
      """)

      schema = Schema.new("Blog.Post", "posts", [], [])
      context = Context.new("Blog", schema, [])
      assert Context.pre_existing?(context)
      refute Context.pre_existing_tests?(context)
      refute Context.pre_existing_test_fixtures?(context)

      File.mkdir_p!("test/phoenix/blog")
      File.write!(context.test_file, """
      defmodule Phoenix.BlogTest do
      end
      """)
      assert Context.pre_existing_tests?(context)

      File.mkdir_p!("test/support/fixtures")
      File.write!(context.test_fixtures_file, """
      defmodule Phoenix.BlogFixtures do
      end
      """)
      assert Context.pre_existing_test_fixtures?(context)
    end
  end

  test "invalid mix arguments", config do
    in_tmp_project config.test, fn ->
      assert_raise Mix.Error, ~r/Expected the context, "blog", to be a valid module name/, fn ->
        Gen.Context.run(~w(blog Post posts title:string))
      end

      assert_raise Mix.Error, ~r/Expected the schema, "posts", to be a valid module name/, fn ->
        Gen.Context.run(~w(Post posts title:string))
      end

      assert_raise Mix.Error, ~r/The context and schema should have different names/, fn ->
        Gen.Context.run(~w(Blog Blog blogs))
      end

      assert_raise Mix.Error, ~r/Cannot generate context Phoenix because it has the same name as the application/, fn ->
        Gen.Context.run(~w(Phoenix Post blogs))
      end

      assert_raise Mix.Error, ~r/Cannot generate schema Phoenix because it has the same name as the application/, fn ->
        Gen.Context.run(~w(Blog Phoenix blogs))
      end

      assert_raise Mix.Error, ~r/Invalid arguments/, fn ->
        Gen.Context.run(~w(Blog.Post posts))
      end

      assert_raise Mix.Error, ~r/Invalid arguments/, fn ->
        Gen.Context.run(~w(Blog Post))
      end
    end
  end

  test "generates context and handles existing contexts", config do
    in_tmp_project config.test, fn ->
      Gen.Context.run(~w(Blog Post posts slug:unique secret:redact title:string))

      assert_file "lib/phoenix/blog/post.ex", fn file ->
        assert file =~ "field :title, :string"
        assert file =~ "field :secret, :string, redact: true"
      end

      assert_file "lib/phoenix/blog.ex", fn file ->
        assert file =~ "def get_post!"
        assert file =~ "def list_posts"
        assert file =~ "def create_post"
        assert file =~ "def update_post"
        assert file =~ "def delete_post"
        assert file =~ "def change_post"
      end

      assert_file "test/phoenix/blog_test.exs", fn file ->
        assert file =~ "use Phoenix.DataCase"
        assert file =~ "describe \"posts\" do"
        assert file =~ "import Phoenix.BlogFixtures"
      end

      assert_file "test/support/fixtures/blog_fixtures.ex", fn file ->
        assert file =~ "defmodule Phoenix.BlogFixtures do"
        assert file =~ "def post_fixture(attrs \\\\ %{})"
        assert file =~ "title: \"some title\""
      end

      assert [path] = Path.wildcard("priv/repo/migrations/*_create_posts.exs")
      assert_file path, fn file ->
        assert file =~ "create table(:posts)"
        assert file =~ "add :title, :string"
        assert file =~ "add :secret, :string"
        assert file =~ "create unique_index(:posts, [:slug])"
      end


      send self(), {:mix_shell_input, :yes?, true}
      Gen.Context.run(~w(Blog Comment comments title:string))

      assert_received {:mix_shell, :info, ["You are generating into an existing context" <> notice]}
      assert notice =~ "Phoenix.Blog context currently has 6 functions and 1 files in its directory"
      assert_received {:mix_shell, :yes?, ["Would you like to proceed?"]}

      assert_file "lib/phoenix/blog/comment.ex", fn file ->
        assert file =~ "field :title, :string"
      end

      assert_file "test/phoenix/blog_test.exs", fn file ->
        assert file =~ "use Phoenix.DataCase"
        assert file =~ "describe \"comments\" do"
        assert file =~ "import Phoenix.BlogFixtures"
      end

      assert_file "test/support/fixtures/blog_fixtures.ex", fn file ->
        assert file =~ "defmodule Phoenix.BlogFixtures do"
        assert file =~ "def comment_fixture(attrs \\\\ %{})"
        assert file =~ "title: \"some title\""
      end

      assert [path] = Path.wildcard("priv/repo/migrations/*_create_comments.exs")
      assert_file path, fn file ->
        assert file =~ "create table(:comments)"
        assert file =~ "add :title, :string"
      end

      assert_file "lib/phoenix/blog.ex", fn file ->
        assert file =~ "def get_comment!"
        assert file =~ "def list_comments"
        assert file =~ "def create_comment"
        assert file =~ "def update_comment"
        assert file =~ "def delete_comment"
        assert file =~ "def change_comment"
      end
    end
  end

  test "generates into existing context without prompt with --merge-with-existing-context", config do
    in_tmp_project config.test, fn ->
      Gen.Context.run(~w(Blog Post posts title))

      assert_file "lib/phoenix/blog.ex", fn file ->
        assert file =~ "def get_post!"
        assert file =~ "def list_posts"
        assert file =~ "def create_post"
        assert file =~ "def update_post"
        assert file =~ "def delete_post"
        assert file =~ "def change_post"
      end

      Gen.Context.run(~w(Blog Comment comments message:string --merge-with-existing-context))

      refute_received {:mix_shell, :info, ["You are generating into an existing context" <> _notice]}

      assert_file "lib/phoenix/blog.ex", fn file ->
        assert file =~ "def get_comment!"
        assert file =~ "def list_comments"
        assert file =~ "def create_comment"
        assert file =~ "def update_comment"
        assert file =~ "def delete_comment"
        assert file =~ "def change_comment"
      end
    end
  end

  test "when more than 50 attributes are given", config do
    in_tmp_project config.test, fn ->
      long_attribute_list = 0..55 |> Enum.map(&("attribute#{&1}:string")) |> Enum.join(" ")
      Gen.Context.run(~w(Blog Post posts title #{long_attribute_list}))

      assert_file "test/phoenix/blog_test.exs", fn file ->
        refute file =~ "...}"
      end
    end
  end


  test "generates context with no schema", config do
    in_tmp_project config.test, fn ->
      Gen.Context.run(~w(Blog Post posts title:string --no-schema))

      refute_file "lib/phoenix/blog/post.ex"

      assert_file "lib/phoenix/blog.ex", fn file ->
        assert file =~ "def get_post!"
        assert file =~ "def list_posts"
        assert file =~ "def create_post"
        assert file =~ "def update_post"
        assert file =~ "def delete_post"
        assert file =~ "def change_post"
        assert file =~ "raise \"TODO\""
      end

      assert_file "test/phoenix/blog_test.exs", fn file ->
        assert file =~ "use Phoenix.DataCase"
        assert file =~ "describe \"posts\" do"
        assert file =~ "import Phoenix.BlogFixtures"
      end

      assert_file "test/support/fixtures/blog_fixtures.ex", fn file ->
        assert file =~ "defmodule Phoenix.BlogFixtures do"
        assert file =~ "def post_fixture(attrs \\\\ %{})"
        assert file =~ "title: \"some title\""
      end

      assert Path.wildcard("priv/repo/migrations/*_create_posts.exs") == []
    end
  end
end
