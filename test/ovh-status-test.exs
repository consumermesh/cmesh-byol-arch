#!/usr/bin/env elixir
# Tests the presentation and control logic in scripts/ovh-status.exs.
#
# The status endpoint's shape is not stable -- it carries a different set of keys depending
# on where the deploy is -- so the two decisions worth pinning down are:
#
#   * terminal?/1 decides when the --watch loop STOPS. Getting it wrong either exits early
#     (missing a failure) or never exits.
#   * render/2 decides what a human sees. Getting it wrong hides the reason a deploy died,
#     and "the script did not end properly" with no context is the failure this project has
#     spent the most time chasing.
#
# The module is EXTRACTED from the script rather than copied, so the two cannot drift.
#
# Usage: elixir test/ovh-status-test.exs

script = Path.join([__DIR__, "..", "scripts", "ovh-status.exs"]) |> Path.expand()

unless File.exists?(script) do
  IO.puts("FATAL: #{script} not found")
  System.halt(1)
end

# The module is everything from `defmodule OvhStatus do` to the line `end` in column 0,
# which is the module's own terminator (the script's main body follows it).
body = File.read!(script)

mod =
  case Regex.run(~r/^defmodule OvhStatus do$.*?^end$/ms, body) do
    [m] -> m
    _ -> nil
  end

unless mod do
  IO.puts("FATAL: could not extract the OvhStatus module from #{script}")
  System.halt(1)
end

tmp = Path.join(System.tmp_dir!(), "ovh-status-mod-#{:erlang.unique_integer([:positive])}.exs")
File.write!(tmp, mod)
Code.require_file(tmp)
File.rm(tmp)

defmodule Checker do
  def check(st, desc, expected, actual) do
    if expected == actual do
      IO.puts("  ok    #{desc}")
      %{st | pass: st.pass + 1}
    else
      IO.puts("""
        FAIL  #{desc}
              expected: #{inspect(expected)}
              actual:   #{inspect(actual)}
      """)

      %{st | fail: st.fail + 1}
    end
  end
end

capture = fn fun ->
  ExUnit.CaptureIO.capture_io(fun)
end

st = %{pass: 0, fail: 0}

IO.puts("=== terminal?/1 decides when the watch loop stops ===")
st = Checker.check(st, "done -> stop", true, OvhStatus.terminal?(%{"status" => "done"}))
st = Checker.check(st, "DONE -> stop (case-insensitive)", true, OvhStatus.terminal?(%{"status" => "DONE"}))
st = Checker.check(st, "error -> stop", true, OvhStatus.terminal?(%{"status" => "error"}))
st = Checker.check(st, "failed -> stop", true, OvhStatus.terminal?(%{"status" => "failed"}))
st = Checker.check(st, "cancelled -> stop", true, OvhStatus.terminal?(%{"status" => "cancelled"}))
st = Checker.check(st, "doing -> keep polling", false, OvhStatus.terminal?(%{"status" => "doing"}))
st = Checker.check(st, "missing status -> keep polling", false, OvhStatus.terminal?(%{}))

IO.puts("\n=== render/2 shows what OVHcloud actually sends ===")

# Shape observed from GET /dedicated/server/{svc}/install/status. `elapsed` is included
# on purpose: a field this script has never seen must be SHOWN, not silently dropped.
doing = %{
  "status" => "doing",
  "progress" => "14/17",
  "comment" => "Running BYOLinux Configure",
  "elapsed" => "00:02:31"
}

out = capture.(fn -> OvhStatus.render(doing, 42) end)
st = Checker.check(st, "shows the status word", true, String.contains?(out, "doing"))
st = Checker.check(st, "shows the progress counter", true, String.contains?(out, "14/17"))
st = Checker.check(st, "shows the comment (where the failing step appears)", true, String.contains?(out, "BYOLinux Configure"))
st = Checker.check(st, "shows elapsed seconds", true, String.contains?(out, "42s"))
st = Checker.check(st, "surfaces an unrecognised field", true, String.contains?(out, "other"))

# 14/17 Configure is where two deploys died, so the error rendering is the important one.
err = %{"status" => "error", "comment" => "The script did not end properly"}
out2 = capture.(fn -> OvhStatus.render(err, 7) end)
st = Checker.check(st, "renders the reason a deploy died", true, String.contains?(out2, "did not end properly"))

# A status with no progress at all must not crash the renderer.
bare = %{"status" => "doing"}
out3 = capture.(fn -> OvhStatus.render(bare, 1) end)
st = Checker.check(st, "tolerates a status with no progress field", true, String.contains?(out3, "doing"))

IO.puts("\n=== signing (same algorithm as ovh-reinstall.exs) ===")
sig = OvhStatus.signature("as", "ck", "GET", "https://eu.api.ovh.com/1.0/x", "", "1700000000")
st = Checker.check(st, "shaped like an OVHcloud signature", true, Regex.match?(~r/^\$1\$[0-9a-f]{40}$/, sig))
st = Checker.check(st, "covers the URL", false, sig == OvhStatus.signature("as", "ck", "GET", "https://eu.api.ovh.com/1.0/y", "", "1700000000"))

IO.puts("\npassed: #{st.pass}  failed: #{st.fail}")
if st.fail > 0, do: System.halt(1)
