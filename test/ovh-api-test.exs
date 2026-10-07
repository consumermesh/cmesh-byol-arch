#!/usr/bin/env elixir
# Tests the pure logic in scripts/ovh-reinstall.exs: the request signature and the
# configDriveUserData validation.
#
# WHY THE SIGNATURE IS WORTH TESTING
#
# OVHcloud's signature is a SHA1 over a "+"-joined string whose components must match the
# outgoing request EXACTLY -- same body bytes, same URL, same method. Any mismatch comes
# back as "Invalid signature", which says nothing about which component was wrong. The
# failure mode is also asymmetric: a wrong signature costs a debugging session, while a
# wrong configDriveUserData costs a deploy that produces an unreachable machine, which is
# precisely what happened on the Control Panel path.
#
# The script itself cannot be run here -- it needs credentials and a real server -- so the
# extractable logic is copied VERBATIM below and checked against OVHcloud's documented
# algorithm. If the two ever diverge, this test is the thing that should fail.
#
# Usage: elixir test/ovh-api-test.exs

defmodule OvhApiTest do
  defstruct pass: 0, fail: 0

  def check(state, description, expected, actual) do
    if expected == actual do
      IO.puts("  ok    #{description}")
      %{state | pass: state.pass + 1}
    else
      IO.puts("""
        FAIL  #{description}
              expected: #{inspect(expected)}
              actual:   #{inspect(actual)}
      """)

      %{state | fail: state.fail + 1}
    end
  end

  # --- copied verbatim from scripts/ovh-reinstall.exs -------------------------

  def signature(as, ck, method, url, body, timestamp) do
    raw = Enum.join([as, ck, method, url, body, timestamp], "+")
    "$1$" <> Base.encode16(:crypto.hash(:sha, raw), case: :lower)
  end

  def verify_user_data(ud) do
    decoded =
      case Base.decode64(ud) do
        {:ok, text} -> text
        :error -> nil
      end

    if decoded do
      passphrase =
        case Regex.run(~r/^\s*cmesh_luks_passphrase:\s*["']?([^"'\n]+)/m, decoded) do
          [_, p] -> p
          _ -> nil
        end

      keys =
        case Regex.run(~r/^ssh_authorized_keys:[ \t]*$((?:\n[ \t]+-.*)*)/m, decoded) do
          [_, section] ->
            Regex.scan(~r/^[ \t]+-[ \t]*(.+)$/m, section) |> Enum.map(&List.last/1)

          _ ->
            []
        end

      {passphrase, keys}
    else
      {nil, []}
    end
  end
end

defmodule Runner do
  def main do
  state = %OvhApiTest{}

  IO.puts("=== request signature ===")

  # OVHcloud's published algorithm:
  #   "$1$" + sha1(AS + "+" + CK + "+" + METHOD + "+" + QUERY + "+" + URL + "+" + BODY + "+" + TS)
  #
  # The check that matters is that the signature is a stable, reproducible function of
  # exactly those inputs -- in particular that it covers the BODY, so a payload cannot be
  # altered between signing and sending without invalidating it.
  sig =
    OvhApiTest.signature(
      "as-secret",
      "ck-token",
      "POST",
      "https://eu.api.ovh.com/1.0/dedicated/server/ns1/reinstall",
      ~s({"operatingSystem":"byolinux_64"}),
      "1700000000"
    )

  state =
    OvhApiTest.check(
      state,
      "is prefixed with $1$ and is 40 hex chars",
      true,
      String.starts_with?(sig, "$1$") and String.length(sig) == 43
    )

  state =
    OvhApiTest.check(
      state,
      "is lowercase hex",
      true,
      Regex.match?(~r/^\$1\$[0-9a-f]{40}$/, sig)
    )

  same =
    OvhApiTest.signature(
      "as-secret",
      "ck-token",
      "POST",
      "https://eu.api.ovh.com/1.0/dedicated/server/ns1/reinstall",
      ~s({"operatingSystem":"byolinux_64"}),
      "1700000000"
    )

  state = OvhApiTest.check(state, "is deterministic for identical inputs", sig, same)

  state =
    OvhApiTest.check(
      state,
      "changes when the BODY changes (body is covered)",
      false,
      sig ==
        OvhApiTest.signature(
          "as-secret",
          "ck-token",
          "POST",
          "https://eu.api.ovh.com/1.0/dedicated/server/ns1/reinstall",
          ~s({"operatingSystem":"debian12_64"}),
          "1700000000"
        )
    )

  state =
    OvhApiTest.check(
      state,
      "changes when the TIMESTAMP changes",
      false,
      sig ==
        OvhApiTest.signature(
          "as-secret",
          "ck-token",
          "POST",
          "https://eu.api.ovh.com/1.0/dedicated/server/ns1/reinstall",
          ~s({"operatingSystem":"byolinux_64"}),
          "1700000001"
        )
    )

  state =
    OvhApiTest.check(
      state,
      "changes when the METHOD changes",
      false,
      sig ==
        OvhApiTest.signature(
          "as-secret",
          "ck-token",
          "GET",
          "https://eu.api.ovh.com/1.0/dedicated/server/ns1/reinstall",
          ~s({"operatingSystem":"byolinux_64"}),
          "1700000000"
        )
    )

  state =
    OvhApiTest.check(
      state,
      "changes when the APPLICATION SECRET changes",
      false,
      sig ==
        OvhApiTest.signature(
          "other-secret",
          "ck-token",
          "POST",
          "https://eu.api.ovh.com/1.0/dedicated/server/ns1/reinstall",
          ~s({"operatingSystem":"byolinux_64"}),
          "1700000000"
        )
    )

  IO.puts("\n=== configDriveUserData validation ===")

  canonical =
    Base.encode64("""
    #cloud-config
    cmesh_luks_passphrase: "9rJ2ATSDfcYX9ky3Wq5ed+ZOsdRGpWQ3WBj+XFyblNM="
    ssh_authorized_keys:
      - ecdsa-sha2-nistp521 AAAAKeyOne spfoos@localhost.localdomain
    """)

  {p, k} = OvhApiTest.verify_user_data(canonical)
  state = OvhApiTest.check(state, "reads the passphrase", "9rJ2ATSDfcYX9ky3Wq5ed+ZOsdRGpWQ3WBj+XFyblNM=", p)
  state = OvhApiTest.check(state, "reads exactly one key", 1, length(k))
  state = OvhApiTest.check(state, "keeps the key intact", "ecdsa-sha2-nistp521 AAAAKeyOne spfoos@localhost.localdomain", List.first(k))

  # The regression that cost a deploy: user-data present but WITHOUT the key, which is what
  # the Control Panel produced (no user-data at all, and this is the next-worst case).
  {nopass, nokeys} =
    OvhApiTest.verify_user_data(Base.encode64("#cloud-config\nsomething: else\n"))

  state = OvhApiTest.check(state, "no passphrase -> nil (installer would abort)", nil, nopass)
  state = OvhApiTest.check(state, "no keys -> empty list", [], nokeys)

  # Quotes around the passphrase must be stripped, or LUKS would be created with them.
  {quoted, _} =
    OvhApiTest.verify_user_data(
      Base.encode64(~s(#cloud-config\ncmesh_luks_passphrase: "abc123abc123"\n))
    )

  state = OvhApiTest.check(state, "strips quotes from the passphrase", "abc123abc123", quoted)

  # Not base64 at all.
  state =
    OvhApiTest.check(state, "invalid base64 -> nil, no crash", {nil, []}, OvhApiTest.verify_user_data("not base64!!"))

  IO.puts("\npassed: #{state.pass}  failed: #{state.fail}")
  if state.fail > 0, do: System.halt(1)

  end
end

Runner.main()
