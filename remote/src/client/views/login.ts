import { themeToggleMarkup } from "../icons";
import { bindThemeToggleButtons } from "../theme";
import { api } from "../transport";
import { escapeText } from "../utils";
import { remoteBrandMarkup } from "../version";

export function renderLogin(app: HTMLElement, onSuccess: () => void, message = ""): void {
  app.innerHTML = `
    <section class="shell auth-shell">
      ${themeToggleMarkup("theme-toggle-floating")}
      <div class="brand">${remoteBrandMarkup()}</div>
      <form class="panel auth-panel" id="login-form">
        <h1>Sign in to your relay</h1>
        <p>Single-user access is required before any local session key can be used.</p>
        <label>
          Username
          <input name="username" autocomplete="username" required />
        </label>
        <label>
          Password
          <input name="password" type="password" autocomplete="current-password" required />
        </label>
        <button type="submit">Sign in</button>
        <output class="form-message">${escapeText(message)}</output>
      </form>
    </section>
  `;

  const form = document.querySelector<HTMLFormElement>("#login-form");
  form?.addEventListener("submit", async (event) => {
    event.preventDefault();
    const data = new FormData(form);
    const res = await api("/api/login", {
      method: "POST",
      body: JSON.stringify({
        username: String(data.get("username") ?? ""),
        password: String(data.get("password") ?? ""),
      }),
    });
    if (!res.ok) {
      renderLogin(app, onSuccess, "Login failed");
      return;
    }
    onSuccess();
  });

  bindThemeToggleButtons();
}
