#!/usr/bin/env elixir
# Live view of an OVHcloud dedicated-server reinstall.
#
# The API reports progress as a flat key/value map whose shape CHANGES as the deploy moves
# through its stages, so a raw GET is hard to read and harder to compare between runs. This
# normalises it into the same numbered steps every time, shows elapsed time, and highlights
# the steps that have actually bitten this project:
#
#   * 14/17  Configure   -- where the deploy hook runs. Two deploys died here: once because
#                           the hook was missing, once because it exited non-zero.
#   * 17/17  done        -- the machine reboots and the FIRST BOOT installer starts
#
# That last transition is the one to watch for, because everything after it happens on the
# machine, not in the API: the deploy is over, and from then on the only evidence is the
# serial console and the installed system itself.
#
# USAGE
#
#   elixir scripts/ovh-status.exs           # print once
#   elixir scripts/ovh-status.exs --watch   # poll until done or failed
#
# Reads deploy.env the same way scripts/ovh-reinstall.exs does.

defmodule OvhStatus do
  # Process-dictionary keys. An anonymous recursive closure cannot rebind a captured
  # variable, so the poll loop's state lives here rather than in a closure.
  def first_seen_key, do: {__MODULE__, :first_seen}
  def last_key_key, do: {__MODULE__, :last}

  # --- settings (mirrors ovh-reinstall.exs; keep the two in step) ---------------

  def load_env! do
    file = Path.join(File.cwd!(), "deploy.env")

    if File.exists?(file) do
      file
      |> File.read!()
      |> String.split("\n")
      |> Enum.each(fn line ->
        line = String.trim(line)

        unless line == "" or String.starts_with?(line, "#") do
          case String.split(line, "=", parts: 2) do
            [k, v] ->
              k = String.trim(k)
              if System.get_env(k) in [nil, ""], do: System.put_env(k, String.trim(v, "\""))

            _ ->
              :ok
          end
        end
      end)
    end

    :ok
  end

  def service_name! do
    load_env!()

    System.get_env("OVH_SERVICE_NAME") ||
      raise "OVH_SERVICE_NAME is not set (put it in deploy.env)"
  end

  def credentials! do
    load_env!()

    %{
      application_key: System.get_env("OVH_APPLICATION_KEY") || raise("OVH_APPLICATION_KEY is not set"),
      application_secret:
        System.get_env("OVH_APPLICATION_SECRET") || raise("OVH_APPLICATION_SECRET is not set"),
      consumer_key: System.get_env("OVH_CONSUMER_KEY") || raise("OVH_CONSUMER_KEY is not set"),
      endpoint: System.get_env("OVH_ENDPOINT") || "ovh-eu"
    }
  end

  def api_base("ovh-eu"), do: "https://eu.api.ovh.com/1.0"
  def api_base("ovh-ca"), do: "https://ca.api.ovh.com/1.0"
  def api_base("ovh-us"), do: "https://api.us.ovhcloud.com/1.0"
  def api_base(other), do: raise("unknown OVH_ENDPOINT: #{other}")

  # --- signing ------------------------------------------------------------------

  def signature(as, ck, method, url, body, timestamp) do
    raw = Enum.join([as, ck, method, url, body, timestamp], "+")
    "$1$" <> Base.encode16(:crypto.hash(:sha, raw), case: :lower)
  end

  def get!(creds, base, path) do
    :inets.start()
    :ssl.start()

    timestamp = System.system_time(:second)

    headers = [
      {~c"X-Ovh-Application", String.to_charlist(creds.application_key)},
      {~c"X-Ovh-Consumer", String.to_charlist(creds.consumer_key)},
      {~c"X-Ovh-Timestamp", String.to_charlist(Integer.to_string(timestamp))},
      {~c"X-Ovh-Signature",
       String.to_charlist(
         signature(
           creds.application_secret,
           creds.consumer_key,
           "GET",
           "#{base}#{path}",
           "",
           timestamp
         )
       )}
    ]

    http_opts = [
      timeout: 30_000,
      ssl: [verify: :verify_peer, cacerts: :public_key.cacerts_get(), depth: 3]
    ]

    case :httpc.request(:get, {String.to_charlist("#{base}#{path}"), headers}, http_opts,
           body_format: :binary
         ) do
      {:ok, {{_, 200, _}, _h, body}} -> decode(body)
      {:ok, {{_, status, _}, _h, body}} -> raise "HTTP #{status}: #{body}"
      {:error, reason} -> raise "request failed: #{inspect(reason)}"
    end
  end

  defp decode(body) do
    case :json.decode(body) do
      json when is_map(json) or is_list(json) -> json
      _ -> body
    end
  rescue
    _ -> body
  end

  # --- presentation -------------------------------------------------------------

  # The endpoint returns the FULL STEP LIST, not a summary:
  #
  #   [%{"comment" => "Checking BIOS version",   "status" => "done",  "error" => ""},
  #    %{"comment" => "Running Hardware Reboot",  "status" => "doing", "error" => ""},
  #    %{"comment" => "Running BYOLinux Configure","status" => "todo", "error" => ""}, ...]
  #
  # 17 steps, in order, one of them "doing". That is far better than a counter: the step
  # names say where a deploy died, and every failure this project has had was at
  # "Running BYOLinux Configure" -- the deploy hook. So the renderer prints the step list
  # with the running step marked, rather than flattening it to a status word.
  @step_icon %{"done" => "ok  ", "doing" => ">>> ", "todo" => "    ", "error" => "ERR "}

  # The endpoint returns an ENVELOPE around the step list:
  #
  #   %{"elapsedTime" => 74, "progress" => [%{"comment" => ..., "status" => ...}, ...]}
  #
  # but it has also been observed returning the bare list. Accept both, and treat an empty
  # list as absent so the caller falls through to the unrecognised branch rather than
  # rendering nothing.
  def steps(%{"progress" => list}) when is_list(list) and list != [], do: list
  def steps(list) when is_list(list) and list != [], do: list
  def steps(_), do: []

  def render(status, elapsed) do
    case steps(status) do
      [] -> render_unknown(status, elapsed)
      list -> render_steps(list, elapsed, api_elapsed(status))
    end
  end

  # The API's own elapsedTime is authoritative when present -- it is the deploy's clock,
  # not ours, and it survives the script being restarted mid-deploy.
  defp api_elapsed(%{"elapsedTime" => t}) when is_integer(t), do: t
  defp api_elapsed(_), do: nil

  defp render_steps(status, elapsed, api_elapsed) do
    total = length(status)
    done = Enum.count(status, &(&1["status"] == "done"))
    errors = Enum.filter(status, &(&1["status"] == "error"))
    doing = Enum.find(status, &(&1["status"] == "doing"))

    shown = api_elapsed || elapsed

    IO.puts("\n=== #{done}/#{total} steps done   (#{shown}s#{if api_elapsed, do: " per API"}) ===")

    if doing do
      IO.puts("running: #{doing["comment"]}")
    end

    if errors != [] do
      IO.puts("\nFAILED:")
      Enum.each(errors, fn e ->
        IO.puts("  #{e["comment"]}")
        if e["error"] not in [nil, ""], do: IO.puts("    #{e["error"]}")
      end)
    end

    IO.puts("")
    Enum.each(status, fn step ->
      icon = Map.get(@step_icon, step["status"], "?   ")
      IO.puts("  #{icon}#{step["comment"]}")
    end)

    :ok
  end

  # An unrecognised shape is printed rather than swallowed: a renderer that crashes
  # mid-deploy is worse than one that shows raw JSON, and this function exists precisely
  # because the shape was guessed wrong twice.
  defp render_unknown(other, elapsed) do
    IO.puts("\n=== unrecognised status shape (#{elapsed}s) ===")
    IO.puts(inspect(other, pretty: true, limit: :infinity))
    :ok
  end

  # Terminal when every step is done, or any step has failed. The deploy is over either
  # way -- and that is the moment the machine reboots and the FIRST BOOT installer starts,
  # which is the part no API can report.
  def terminal?(status) do
    case steps(status) do
      [] ->
        false

      list ->
        Enum.any?(list, &(&1["status"] in ["error", "failed", "cancelled"])) or
          Enum.all?(list, &(&1["status"] == "done"))
    end
  end
end

creds = OvhStatus.credentials!()
base = OvhStatus.api_base(creds.endpoint)
service = OvhStatus.service_name!()
path = "/dedicated/server/#{service}/install/status"

IO.puts("watching #{service} via #{creds.endpoint}")

run = fn run ->
  status = OvhStatus.get!(creds, base, path)
  now = :calendar.universal_time()

  elapsed =
    case Process.get(OvhStatus.first_seen_key()) do
      nil ->
        Process.put(OvhStatus.first_seen_key(), now)
        0

      t ->
        :calendar.datetime_to_gregorian_seconds(now) -
          :calendar.datetime_to_gregorian_seconds(t)
    end

  key = status |> OvhStatus.steps() |> Enum.map(&{&1["comment"], &1["status"]})

  if key != Process.get(OvhStatus.last_key_key()) do
    Process.put(OvhStatus.last_key_key(), key)
    OvhStatus.render(status, elapsed)

    if OvhStatus.terminal?(status) and
         not Enum.any?(OvhStatus.steps(status), &(&1["status"] == "error")) do
      IO.puts("""

      >>> The deploy is FINISHED. The machine is rebooting into the deployed image, and the
      >>> first-boot installer takes over from here.
      >>>
      >>> Everything after this point happens ON THE MACHINE, not in the API. Watch the KVM
      >>> console for:
      >>>     cmesh-byol-bootloader: ...      (the deploy hook, already done)
      >>>     === cmesh-byol-install starting  (the installer -- it has never run before)
      >>>
      >>> Expect a long silence while it stages the rootfs into RAM. Do not reboot.
      """)
    end
  end

  if OvhStatus.terminal?(status) do
    :done
  else
    Process.sleep(10_000)
    run.(run)
  end
end

if "--watch" in System.argv() do
  run.(run)
else
  status = OvhStatus.get!(creds, base, path)
  OvhStatus.render(status, 0)

  unless OvhStatus.terminal?(status) do
    IO.puts("\n(re-run with --watch to poll until it finishes)")
  end
end
