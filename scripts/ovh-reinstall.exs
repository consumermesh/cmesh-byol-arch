#!/usr/bin/env elixir
# Reinstalls a dedicated server with the BYOLinux image described by deploy.json, using
# the OVHcloud API directly.
#
# WHY THIS EXISTS INSTEAD OF THE CONTROL PANEL
#
# `configDriveUserData` is the only channel that carries two things this deployment
# cannot work without:
#
#   * cmesh_luks_passphrase -- the installer aborts with a FATAL message without it
#   * ssh_authorized_keys   -- without it the installed system has sshd but no way in
#
# The Control Panel path lost it. A deploy came back with a config drive holding no
# user-data at all, so the server was unreachable by construction and the installer could
# never have run. The API takes the field verbatim, and this script prints it back before
# sending anything so a mistake is visible while it is still free.
#
# WHY THE TIMESTAMP DANCE
#
# OVHcloud signs each request with a timestamp that must be within a few minutes of THEIR
# clock, not yours:
#
#   "$1$" <> sha1_hex(AS <> "+" <> CK <> "+" <> METHOD <> "+" <> QUERY <> "+" <> URL
#                    <> "+" <> BODY <> "+" <> TIMESTAMP)
#
# and the timestamp must be in the future. A skewed local clock therefore fails as
# "Invalid signature", which is a maddening error to debug. So the server's time is
# fetched from /auth/time, and the request is sent at target - window.
#
# USAGE
#
# OVH_APPLICATION_KEY=... OVH_APPLICATION_SECRET=... OVH_CONSUMER_KEY=... \
#   elixir scripts/ovh-reinstall.exs [--yes] [--json PATH]
#
# Credentials come from the OVHcloud API console (https://api.ovh.com/createToken/) and
# need these rights:
#
#   GET  /dedicated/server/*
#   POST /dedicated/server/*/reinstall
#   GET  /dedicated/server/*/install/status
#
# Run without --yes to do everything except send: it resolves credentials, reaches the
# API, prints the exact payload, and stops. That dry run is the point -- it proves the
# signing works and shows the body before a disk is touched.

defmodule OvhReinstall do
  @pre_request_window 5

  # ---------------------------------------------------------------------------
  # Credentials
  # ---------------------------------------------------------------------------

  def credentials! do
    # .env is read because the application secret is shown exactly once when the token is
    # created; re-pasting it every run is how it ends up in shell history.
    env = load_env_file()

    creds = %{
      application_key: fetch!(env, "OVH_APPLICATION_KEY"),
      application_secret: fetch!(env, "OVH_APPLICATION_SECRET"),
      consumer_key: fetch!(env, "OVH_CONSUMER_KEY"),
      endpoint: env["OVH_ENDPOINT"] || System.get_env("OVH_ENDPOINT") || "ovh-eu"
    }

    creds
  end

  defp load_env_file do
    path = Path.join([File.cwd!(), "deploy.env"])

    if File.exists?(path) do
      path
      |> File.read!()
      |> String.split("\n")
      |> Enum.reduce(%{}, fn line, acc ->
        line = String.trim(line)

        cond do
          line == "" -> acc
          String.starts_with?(line, "#") -> acc
          true ->
            case String.split(line, "=", parts: 2) do
              [k, v] -> Map.put(acc, String.trim(k), v |> String.trim() |> String.trim("\""))
              _ -> acc
            end
        end
      end)
    else
      %{}
    end
  end

  defp fetch!(env, key) do
    env[key] || System.get_env(key) ||
      raise """
      #{key} is not set.

      Put it in deploy.env next to this repo (gitignored), or export it:

        OVH_APPLICATION_KEY     from https://api.ovh.com/createToken/
        OVH_APPLICATION_SECRET
        OVH_CONSUMER_KEY
      """
  end

  def api_base("ovh-eu"), do: "https://eu.api.ovh.com/1.0"
  def api_base("ovh-ca"), do: "https://ca.api.ovh.com/1.0"
  def api_base("ovh-us"), do: "https://api.us.ovhcloud.com/1.0"
  def api_base(other), do: raise("unknown OVH_ENDPOINT: #{other}")

  # ---------------------------------------------------------------------------
  # Signing
  # ---------------------------------------------------------------------------

  def server_time!(base) do
    case request(:get, "#{base}/auth/time", [], "") do
      {200, t} when is_integer(t) -> t
      {status, body} -> raise "GET /auth/time returned HTTP #{status}: #{inspect(body)}"
    end
  end

  # :httpc rather than Req or Finch. This script must run on a bare host with nothing but
  # Elixir and Erlang -- no Mix project, no deps -- because the moment it needs `mix deps.get`
  # it stops being the thing you reach for when a server is already broken.
  def request(method, url, headers, body) do
    :inets.start()
    :ssl.start()

    hdrs = Enum.map(headers, fn {k, v} -> {String.to_charlist(k), String.to_charlist(v)} end)

    http_opts = [
      timeout: 60_000,
      connect_timeout: 15_000,
      ssl: [verify: :verify_peer, cacerts: :public_key.cacerts_get(), depth: 3]
    ]

    req =
      case method do
        :get -> {String.to_charlist(url), hdrs}
        :post -> {String.to_charlist(url), hdrs, ~c"application/json", body}
      end

    case :httpc.request(method, req, http_opts, body_format: :binary) do
      {:ok, {{_, status, _}, _resp_headers, resp_body}} -> {status, decode(resp_body)}
      {:error, reason} -> raise "request to #{url} failed: #{inspect(reason)}"
    end
  end

  def signature(creds, method, url, body, timestamp) do
    raw =
      Enum.join(
        [
          creds.application_secret,
          creds.consumer_key,
          method,
          url,
          body,
          timestamp
        ],
        "+"
      )

    "$1$" <> Base.encode16(:crypto.hash(:sha, raw), case: :lower)
  end

  def signed_request!(creds, base, method, path, body_map) do
    # The body string that is SIGNED must be byte-identical to the one SENT, so it is
    # encoded once. Re-encoding between signing and sending is a classic source of
    # "Invalid signature" with a body that looks perfectly correct.
    body = if body_map, do: to_string(:json.encode(body_map)), else: ""

    # OVHcloud validates against the time the request ARRIVES, so the timestamp is placed
    # slightly in the future and we wait for it. Sending immediately fails intermittently.
    target = server_time!(base) + @pre_request_window
    timestamp = target - @pre_request_window

    delay = target - System.system_time(:second)
    if delay > 0, do: Process.sleep(delay * 1000)

    headers = [
      {"X-Ovh-Application", creds.application_key},
      {"X-Ovh-Consumer", creds.consumer_key},
      {"X-Ovh-Timestamp", Integer.to_string(timestamp)},
      {"X-Ovh-Signature", signature(creds, method, "#{base}#{path}", body, timestamp)},
      {"Content-Type", "application/json"}
    ]

    verb = if method == "GET", do: :get, else: :post
    request(verb, "#{base}#{path}", headers, body)
  end

  defp decode(body) when is_binary(body) do
    # A bare JSON scalar does not decode to an Elixir term, it comes back as its own text:
    # GET /auth/time returns the integer 1791337290 as the binary "1791337290". OVHcloud has
    # several endpoints like this, so it is handled here rather than at each call site.
    case Integer.parse(body) do
      {int, ""} ->
        int

      _ ->
        case :json.decode(body) do
          json when is_map(json) or is_list(json) -> json
          _ -> body
        end
    end
  rescue
    _ -> body
  end

  defp decode(body), do: body

  # ---------------------------------------------------------------------------
  # The payload
  # ---------------------------------------------------------------------------

  def decode_file!(path) do
    case :json.decode(File.read!(path)) do
      map when is_map(map) -> map
      other -> raise "#{path} is not a JSON object: #{inspect(other)}"
    end
  rescue
    e in ArgumentError -> raise "#{path} is not valid JSON: #{Exception.message(e)}"
  end

  def pretty(term), do: term |> :json.encode() |> IO.iodata_to_binary() |> pretty_json()

  # :json has no pretty printer, and the dry run's whole value is being readable.
  defp pretty_json(json) do
    json
    |> String.replace("{", "{\n  ")
    |> String.replace("}", "\n}")
    |> String.replace(",", ",\n  ")
  end

  def load_deploy!(path) do
    unless File.exists?(path) do
      raise "#{path} not found. It is the reinstall payload and is gitignored (it holds " <>
              "the LUKS passphrase)."
    end

    decode_file!(path)
  end

  # The one thing this script exists to guarantee: the config drive carries user-data.
  def verify_user_data!(deploy) do
    ud = get_in(deploy, ["customizations", "configDriveUserData"])

    unless is_binary(ud) and ud != "" do
      raise """
      customizations.configDriveUserData is missing or empty.

      That field is the ONLY channel carrying the LUKS passphrase and the SSH key. A deploy
      without it produces a server that cannot be logged into and whose installer aborts.
      """
    end

    decoded =
      case Base.decode64(ud) do
        {:ok, text} -> text
        :error -> raise "configDriveUserData is not valid base64"
      end

    passphrase =
      case Regex.run(~r/^\s*cmesh_luks_passphrase:\s*["']?([^"'\n]+)/m, decoded) do
        [_, p] -> p
        _ -> nil
      end

    keys =
      case Regex.run(~r/^ssh_authorized_keys:[ \t]*$((?:\n[ \t]+-.*)*)/m, decoded) do
        [_, section] -> Regex.scan(~r/^[ \t]+-[ \t]*(.+)$/m, section) |> Enum.map(&List.last/1)
        _ -> []
      end

    unless passphrase do
      raise "configDriveUserData has no cmesh_luks_passphrase; the installer would abort."
    end

    if keys == [] do
      IO.puts("""
      !! WARNING: configDriveUserData carries no ssh_authorized_keys.
      !! The install will succeed and the machine will have sshd running with no key --
      !! unreachable except through the KVM console.
      """)
    end

    %{passphrase: passphrase, keys: keys, decoded: decoded}
  end
end

# -----------------------------------------------------------------------------
# main
# -----------------------------------------------------------------------------

{opts, _argv, _invalid} =
  OptionParser.parse(System.argv(),
    strict: [yes: :boolean, json: :string, help: :boolean],
    aliases: [y: :yes, h: :help]
  )

if opts[:help] do
  IO.puts("""
  Reinstall a dedicated server with the image in deploy.json.

    elixir scripts/ovh-reinstall.exs            # dry run: sign, print, stop
    elixir scripts/ovh-reinstall.exs --yes      # actually submit

    --json PATH   payload to use (default: deploy.json next to this repo)
  """)

  System.halt(0)
end

deploy_path = opts[:json] || Path.join([File.cwd!(), "deploy.json"])
deploy = OvhReinstall.load_deploy!(deploy_path)
config = OvhReinstall.verify_user_data!(deploy)
creds = OvhReinstall.credentials!()
base = OvhReinstall.api_base(creds.endpoint)

service_name =
  System.get_env("OVH_SERVICE_NAME") ||
    raise "OVH_SERVICE_NAME is not set (e.g. ns5004419.ip-51-222-11.net)"

IO.puts("""
=== cmesh-byol-arch reinstall ===
  payload    : #{deploy_path}
  endpoint   : #{creds.endpoint} (#{base})
  server     : #{service_name}
  image      : #{get_in(deploy, ["customizations", "imageURL"])}
  checksum   : #{String.slice(get_in(deploy, ["customizations", "imageCheckSum"]) || "", 0, 16)}...
  passphrase : #{String.length(config.passphrase)} chars (read from configDriveUserData)
  ssh keys   : #{length(config.keys)}#{if config.keys != [], do: " -> " <> List.last(config.keys), else: ""}
""")

IO.puts("--- config drive user-data, decoded ---")
IO.puts(config.decoded)
IO.puts("--- end ---\n")

# Prove signing works before doing anything destructive. A GET costs nothing and
# exercises the exact signing path the POST will use.
IO.puts("checking credentials with GET /dedicated/server/#{service_name} ...")

case OvhReinstall.signed_request!(creds, base, "GET", "/dedicated/server/#{service_name}", nil) do
  {200, %{"name" => name}} ->
    IO.puts("  authenticated OK (server reports name=#{name})")

  {status, body} ->
    raise """
    authentication/authorisation failed: HTTP #{status}
    #{inspect(body)}

    403 usually means the token's allowed paths do not cover this call. Create a token at
    https://api.ovh.com/createToken/ with:
      GET  /dedicated/server/*
      POST /dedicated/server/*/reinstall
    """
end

unless opts[:yes] do
  IO.puts("""

  DRY RUN -- nothing was submitted.

  The payload that WOULD be sent to POST /dedicated/server/#{service_name}/reinstall:

  #{OvhReinstall.pretty(deploy)}

  Re-run with --yes to submit. This ERASES the server.
  """)

  System.halt(0)
end

IO.puts("\nsubmitting reinstall ...")

case OvhReinstall.signed_request!(
       creds,
       base,
       "POST",
       "/dedicated/server/#{service_name}/reinstall",
       deploy
     ) do
  {status, body} when status in 200..299 ->
    IO.puts("  accepted: HTTP #{status}")
    IO.puts("  #{inspect(body)}")
    IO.puts("\nTrack it with: GET /dedicated/server/#{service_name}/install/status")
    IO.puts("The machine will reboot when OVHcloud begins; watch the KVM console.")

  {status, body} ->
    raise """
    reinstall rejected: HTTP #{status}
    #{inspect(body)}

    OVHcloud reports the reason in `message` for this endpoint -- read it before retrying.
    """
end
