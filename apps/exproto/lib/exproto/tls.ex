defmodule ExProto.TLS do
  @moduledoc """
  Certificate material for a controller that has no CA, no DNS, and no internet.

  A robot on a shop floor cannot get a certificate from a public CA: there is no
  resolvable name to validate and often no route out. So the controller mints
  its own on first boot, keeps it, and publishes its fingerprint — and clients
  pin that fingerprint the way an SSH client pins a host key.

  ## Trust on first use, said out loud

  This is TOFU, with all of TOFU's properties. The first connection is
  unauthenticated and could be intercepted; every connection after it is
  authenticated against what was seen the first time, and a changed fingerprint
  is loud. That is materially weaker than a real PKI and materially stronger
  than plaintext, and pretending otherwise in either direction helps nobody.

  What it buys concretely: traffic is encrypted, so joint positions and program
  contents are not readable by anything else on the shop floor network, and a
  swapped-in controller cannot silently impersonate the original.

  What it does not buy: protection from someone who is on the network *before*
  the operator's first connection. A site that needs that installs its own CA
  and passes `certfile`/`keyfile` explicitly, which this module supports and
  does not get in the way of.

  ## Why EC rather than RSA

  A P-256 key is a few hundred bytes against RSA-2048's couple of thousand,
  generates in milliseconds rather than seconds on a Pi, and makes the handshake
  cheaper — which matters when a pendant reconnects on every page load.

  ## Fingerprints

  SHA-256 over the DER, uppercase hex, colon separated. The same format
  `openssl x509 -fingerprint -sha256` prints, so an operator can verify a
  controller from a laptop without any E-Motion tooling.
  """

  require Logger

  @type material :: %{certfile: String.t(), keyfile: String.t(), fingerprint: String.t()}

  @cert_name "controller.pem"
  @key_name "controller-key.pem"

  # Ten years. A controller that stops accepting connections because a
  # certificate quietly expired is an outage nobody will diagnose quickly, and
  # rotation here is a deliberate act rather than a calendar event — the trust
  # anchor is the pinned fingerprint, not an expiry date.
  @validity_days 3650

  @doc """
  Returns usable certificate material, generating it on first call.

  Options:

    * `:dir` — where to keep the pair. Required unless both `:certfile` and
      `:keyfile` are given.
    * `:certfile` / `:keyfile` — use an existing pair, for a site with its own CA
    * `:hostnames` — names to put in the SAN, defaults to the controller's own
      hostname plus `emotion.local` and `localhost`
  """
  @spec material(keyword()) :: {:ok, material()} | {:error, term()}
  def material(opts) do
    case {opts[:certfile], opts[:keyfile]} do
      {certfile, keyfile} when is_binary(certfile) and is_binary(keyfile) ->
        with {:ok, pem} <- File.read(certfile) do
          {:ok, %{certfile: certfile, keyfile: keyfile, fingerprint: fingerprint_from_pem(pem)}}
        end

      _ ->
        ensure_self_signed(opts)
    end
  end

  @doc """
  The SSL options for a listener.

  TLS 1.2 is the floor. Anything older has no place on a network segment that
  can move a robot arm, and every client this controller cares about — a
  browser, an Elixir client, a Python integrator — has spoken 1.2 for a decade.
  """
  @spec ssl_options(material()) :: keyword()
  def ssl_options(%{certfile: certfile, keyfile: keyfile}) do
    [
      certfile: certfile,
      keyfile: keyfile,
      versions: [:"tlsv1.3", :"tlsv1.2"],
      # No client certificates. Authentication is a token in the handshake;
      # mutual TLS on a device with no CA would mean minting client certs
      # too, which is a key-management problem an operator will not do.
      verify: :verify_none,
      secure_renegotiate: true,
      reuse_sessions: true,
      honor_cipher_order: true
    ]
  end

  @doc "SHA-256 fingerprint of a DER-encoded certificate, colon separated."
  @spec fingerprint(binary()) :: String.t()
  def fingerprint(der) when is_binary(der) do
    :crypto.hash(:sha256, der)
    |> Base.encode16()
    |> String.to_charlist()
    |> Enum.chunk_every(2)
    |> Enum.map_join(":", &to_string/1)
  end

  @doc "SHA-256 fingerprint of the first certificate in a PEM."
  @spec fingerprint_from_pem(binary()) :: String.t()
  def fingerprint_from_pem(pem) do
    pem
    |> :public_key.pem_decode()
    |> Enum.find(&match?({:Certificate, _der, _}, &1))
    |> case do
      {:Certificate, der, _} -> fingerprint(der)
      nil -> raise ArgumentError, "no certificate found in PEM"
    end
  end

  # ── Generation ────────────────────────────────────────────────────────────

  defp ensure_self_signed(opts) do
    dir = Keyword.fetch!(opts, :dir)
    certfile = Path.join(dir, @cert_name)
    keyfile = Path.join(dir, @key_name)

    if File.exists?(certfile) and File.exists?(keyfile) do
      {:ok, pem} = File.read(certfile)

      {:ok, %{certfile: certfile, keyfile: keyfile, fingerprint: fingerprint_from_pem(pem)}}
    else
      generate(dir, certfile, keyfile, hostnames(opts))
    end
  end

  defp generate(dir, certfile, keyfile, hostnames) do
    File.mkdir_p!(dir)

    key = X509.PrivateKey.new_ec(:secp256r1)

    certificate =
      X509.Certificate.self_signed(
        key,
        "/CN=E-Motion Controller/O=E-Motion",
        template: template(hostnames)
      )

    File.write!(certfile, X509.Certificate.to_pem(certificate))
    File.write!(keyfile, X509.PrivateKey.to_pem(key))

    # The private key is the whole of the controller's identity. World-readable
    # is the default on a fresh directory and is not acceptable for this.
    File.chmod!(keyfile, 0o600)
    File.chmod!(certfile, 0o644)

    print = fingerprint(X509.Certificate.to_der(certificate))

    Logger.info("""
    Generated a self-signed certificate for this controller.

      fingerprint  #{print}
      names        #{Enum.join(hostnames, ", ")}
      stored in    #{dir}

    Clients pin this fingerprint on first connection. Verify it out of band
    before trusting a controller you have not connected to before.
    """)

    {:ok, %{certfile: certfile, keyfile: keyfile, fingerprint: print}}
  end

  defp template(hostnames) do
    X509.Certificate.Template.new(:server,
      validity: @validity_days,
      extensions: [
        subject_alt_name: X509.Certificate.Extension.subject_alt_name(hostnames)
      ]
    )
  end

  # A controller is reached by mDNS name, by bare hostname, and by address, and
  # a certificate that only covers one of them produces a warning on the other
  # two — which teaches an operator to click through warnings.
  defp hostnames(opts) do
    case opts[:hostnames] do
      names when is_list(names) and names != [] ->
        names

      _ ->
        {:ok, host} = :inet.gethostname()
        host = to_string(host)

        Enum.uniq([host, "#{host}.local", "emotion.local", "localhost"])
    end
  end
end
