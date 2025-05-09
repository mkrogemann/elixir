# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2021 The Elixir Team
# SPDX-FileCopyrightText: 2012 Plataformatec

Code.require_file("../../test_helper.exs", __DIR__)

defmodule Mix.Tasks.Compile.ErlangTest do
  use MixTest.Case
  import ExUnit.CaptureIO

  defmacro position(line, column), do: {line, column}

  setup config do
    erlc_options = Map.get(config, :erlc_options, [])
    Mix.ProjectStack.post_config(erlc_options: erlc_options)
    Mix.Project.push(MixTest.Case.Sample)
    :ok
  end

  @tag erlc_options: [{:d, ~c"foo", ~c"bar"}]
  test "raises on invalid erlc_options" do
    in_fixture("compile_erlang", fn ->
      assert_raise Mix.Error, ~r/Compiling Erlang file ".*" failed/, fn ->
        capture_io(fn ->
          Mix.Tasks.Compile.Erlang.run([])
        end)
      end
    end)
  end

  test "compiles and cleans src/b.erl and src/c.erl" do
    in_fixture("compile_erlang", fn ->
      assert Mix.Tasks.Compile.Erlang.run(["--verbose"]) == {:ok, []}
      assert_received {:mix_shell, :info, ["Compiled src/b.erl"]}
      assert_received {:mix_shell, :info, ["Compiled src/c.erl"]}

      assert File.regular?("_build/dev/lib/sample/ebin/b.beam")
      assert File.regular?("_build/dev/lib/sample/ebin/c.beam")

      assert Mix.Tasks.Compile.Erlang.run(["--verbose"]) == {:noop, []}
      refute_received {:mix_shell, :info, ["Compiled src/b.erl"]}

      assert Mix.Tasks.Compile.Erlang.run(["--force", "--verbose"]) == {:ok, []}
      assert_received {:mix_shell, :info, ["Compiled src/b.erl"]}
      assert_received {:mix_shell, :info, ["Compiled src/c.erl"]}

      assert Mix.Tasks.Compile.Erlang.clean()
      refute File.regular?("_build/dev/lib/sample/ebin/b.beam")
      refute File.regular?("_build/dev/lib/sample/ebin/c.beam")
    end)
  end

  test "removes old artifact files" do
    in_fixture("compile_erlang", fn ->
      assert Mix.Tasks.Compile.Erlang.run([]) == {:ok, []}
      assert File.regular?("_build/dev/lib/sample/ebin/b.beam")

      File.rm!("src/b.erl")
      assert Mix.Tasks.Compile.Erlang.run([]) == {:ok, []}
      refute File.regular?("_build/dev/lib/sample/ebin/b.beam")
    end)
  end

  test "compilation purges the module" do
    in_fixture("compile_erlang", fn ->
      # Create the first version of the module.
      defmodule :purge_test do
        def version, do: :v1
      end

      assert :v1 == :purge_test.version()

      # Create the second version of the module (this time as Erlang source).
      File.write!("src/purge_test.erl", """
      -module(purge_test).
      -export([version/0]).
      version() -> v2.
      """)

      assert Mix.Tasks.Compile.Erlang.run([]) == {:ok, []}

      # If the module was not purged on recompilation, this would fail.
      assert :v2 == :purge_test.version()
    end)
  end

  test "continues even if one file fails to compile" do
    in_fixture("compile_erlang", fn ->
      file = Path.absname("src/zzz.erl")
      source = deterministic_source(file)

      File.write!(file, """
      -module(zzz).
      def zzz(), do: b
      """)

      capture_io(fn ->
        assert {:error, [diagnostic]} = Mix.Tasks.Compile.Erlang.run([])

        assert %Mix.Task.Compiler.Diagnostic{
                 compiler_name: "erl_parse",
                 file: ^source,
                 source: ^source,
                 message: "syntax error before: zzz",
                 position: position(2, 5),
                 severity: :error
               } = diagnostic
      end)

      assert File.regular?("_build/dev/lib/sample/ebin/b.beam")
      assert File.regular?("_build/dev/lib/sample/ebin/c.beam")
    end)
  end

  test "saves warnings between builds" do
    in_fixture("compile_erlang", fn ->
      file = Path.absname("src/has_warning.erl")
      source = deterministic_source(file)

      File.write!(file, """
      -module(has_warning).
      my_fn() -> ok.
      """)

      capture_io(fn ->
        assert {:ok, [diagnostic]} = Mix.Tasks.Compile.Erlang.run([])

        assert %Mix.Task.Compiler.Diagnostic{
                 file: ^source,
                 source: ^source,
                 compiler_name: "erl_lint",
                 message: "function my_fn/0 is unused",
                 position: position(2, 1),
                 severity: :warning
               } = diagnostic

        capture_io(:stderr, fn ->
          # Should return warning without recompiling file
          assert {:noop, [^diagnostic]} = Mix.Tasks.Compile.Erlang.run(["--verbose"])
          refute_received {:mix_shell, :info, ["Compiled src/has_warning.erl"]}

          assert [^diagnostic] = Mix.Tasks.Compile.Erlang.diagnostics()
          assert [^diagnostic] = Mix.Task.Compiler.diagnostics()

          # Should not return warning after changing file
          File.write!(file, """
          -module(has_warning).
          -export([my_fn/0]).
          my_fn() -> ok.
          """)

          ensure_touched(file)
          assert {:ok, []} = Mix.Tasks.Compile.Erlang.run([])
        end)
      end)
    end)
  end

  test "prints warnings from stale files with --all-warnings" do
    in_fixture("compile_erlang", fn ->
      file = Path.absname("src/has_warning.erl")

      File.write!(file, """
      -module(has_warning).
      my_fn() -> ok.
      """)

      capture_io(fn -> Mix.Tasks.Compile.Erlang.run([]) end)

      assert capture_io(:stderr, fn ->
               assert {:noop, _} = Mix.Tasks.Compile.Erlang.run([])
             end) =~ ~r"has_warning.erl:2:(1:)? warning: function my_fn/0 is unused\n"

      assert capture_io(:stderr, fn ->
               assert {:noop, _} = Mix.Tasks.Compile.Erlang.run([])
             end) =~ ~r"has_warning.erl:2:(1:)? warning: function my_fn/0 is unused\n"

      # Should not print old warnings after fixing
      File.write!(file, """
      -module(has_warning).
      """)

      ensure_touched(file)

      output =
        capture_io(fn ->
          Mix.Tasks.Compile.Erlang.run(["--all-warnings"])
        end)

      assert output == ""
    end)
  end

  test "returns syntax error from an Erlang file when --return-errors is set" do
    in_fixture("no_mixfile", fn ->
      import ExUnit.CaptureIO

      file = Path.absname("src/a.erl")
      source = deterministic_source(file)

      File.mkdir!("src")

      File.write!(file, """
      -module(b).
      def b(), do: b
      """)

      capture_io(fn ->
        assert {:error, [diagnostic]} =
                 Mix.Tasks.Compile.Erlang.run(["--force", "--return-errors"])

        assert %Mix.Task.Compiler.Diagnostic{
                 compiler_name: "erl_parse",
                 file: ^source,
                 source: ^source,
                 message: "syntax error before: b",
                 position: position(2, 5),
                 severity: :error
               } = diagnostic
      end)

      refute File.regular?("ebin/Elixir.A.beam")
      refute File.regular?("ebin/Elixir.B.beam")
    end)
  end

  @tag erlc_options: [{:warnings_as_errors, true}]
  test "adds :debug_info to erlc_options by default" do
    in_fixture("compile_erlang", fn ->
      Mix.Tasks.Compile.Erlang.run([])

      binary = File.read!("_build/dev/lib/sample/ebin/b.beam")

      {:ok, {_, [debug_info: {:debug_info_v1, _, {debug_info, _}}]}} =
        :beam_lib.chunks(binary, [:debug_info])

      assert debug_info != :none
    end)
  end

  if :deterministic in :compile.env_compiler_options() do
    defp deterministic_source(file), do: Path.basename(file)
  else
    defp deterministic_source(file), do: file
  end
end
