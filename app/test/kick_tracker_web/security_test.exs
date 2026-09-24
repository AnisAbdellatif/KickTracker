defmodule KickTrackerWeb.SecurityTest do
  use KickTrackerWeb.ConnCase, async: false

  alias KickTrackerWeb.Plugs.RemoteIp

  describe "the visitor's address behind our proxies" do
    test "is read from X-Forwarded-For only when the request came through a proxy of ours" do
      assert RemoteIp.pick(["203.0.113.9, 10.0.0.2"], 1) == {:ok, {10, 0, 0, 2}}
      assert RemoteIp.pick(["1.2.3.4", "203.0.113.9"], 1) == {:ok, {203, 0, 113, 9}}
      assert RemoteIp.pick(["spoofed, 203.0.113.9, 198.51.100.7"], 2) == {:ok, {203, 0, 113, 9}}
      assert RemoteIp.pick(["garbage"], 1) == :error
      assert RemoteIp.pick([], 1) == :error

      proxied =
        %{build_conn() | remote_ip: {172, 18, 0, 5}}
        |> put_req_header("x-forwarded-for", "9.9.9.9, 203.0.113.9")

      assert RemoteIp.call(proxied, []).remote_ip == {203, 0, 113, 9}

      # A client talking to us directly can't choose its address.
      direct =
        %{build_conn() | remote_ip: {198, 51, 100, 7}}
        |> put_req_header("x-forwarded-for", "203.0.113.9")

      assert RemoteIp.call(direct, []).remote_ip == {198, 51, 100, 7}
    end
  end

  test "pages carry a CSP whose nonce is on the inline script", %{conn: conn} do
    conn = get(conn, "/about/methodology")
    [csp] = get_resp_header(conn, "content-security-policy")
    [_, nonce] = Regex.run(~r/'nonce-([^']+)'/, csp)

    assert csp =~ "default-src 'self'" and csp =~ "frame-ancestors 'self'" and
             csp =~ "object-src 'none'"

    assert html_response(conn, 200) =~ ~s(nonce="#{nonce}")
    refute csp =~ "unsafe-eval"
    assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
  end

  describe "rate limits" do
    setup do
      previous = Application.get_env(:kick_tracker, :rate_limits)
      Application.put_env(:kick_tracker, :rate_limits, pages: 3, data: 2, login: 2)
      on_exit(fn -> Application.put_env(:kick_tracker, :rate_limits, previous) end)
      # A fresh address per test, so counts don't carry over.
      %{ip: {203, 0, 113, System.unique_integer([:positive]) |> rem(250)}}
    end

    test "pages and data answer 429 with Retry-After past the limit", %{ip: ip} do
      conn = fn -> %{build_conn() | remote_ip: ip} end
      for _ <- 1..3, do: assert(get(conn.(), "/about/privacy").status == 200)
      limited = get(conn.(), "/about/privacy")
      assert limited.status == 429
      assert [retry] = get_resp_header(limited, "retry-after")
      assert String.to_integer(retry) in 1..60

      # Health checks are never limited.
      assert get(conn.(), "/healthz").status == 200
    end

    test "failed logins are throttled", %{ip: ip} do
      attempt = fn ->
        post(%{build_conn() | remote_ip: ip}, "/admin/login",
          admin: %{email: "x@example.com", password: "nope nope nope", code: "000000"}
        )
      end

      assert attempt.().status == 200
      assert attempt.().status == 200
      assert attempt.().status == 429
    end

    test "20 failed logins in 10 minutes shut an address out for an hour", %{ip: ip} do
      Application.put_env(:kick_tracker, :rate_limits, pages: 1_000, data: 1_000, login: 1_000)

      attempt = fn ->
        post(%{build_conn() | remote_ip: ip}, "/admin/login",
          admin: %{email: "x@example.com", password: "nope nope nope", code: "000000"}
        )
      end

      for _ <- 1..20, do: assert(attempt.().status == 200)
      assert attempt.().status == 429
    end
  end
end
