const form = document.getElementById("key-form");
const input = document.getElementById("api-key");
const error = document.getElementById("key-error");
const submitButton = form.querySelector('button[type="submit"]');

form.addEventListener("submit", (event) => {
  event.preventDefault();
  const key = input.value.trim();
  if (!key) {
    error.textContent = "Informe sua chave da API para continuar.";
    input.focus();
    return;
  }
  error.textContent = "";
  submitButton.disabled = true;
  submitButton.textContent = "Iniciando…";
  window.scalpingDesktop.submitApiKey(key);
  input.value = "";
});

document.getElementById("cancel-button").addEventListener("click", () => {
  window.scalpingDesktop.cancelApiKey();
});

window.scalpingDesktop.onApiKeyError((message) => {
  error.textContent = message;
  submitButton.disabled = false;
  submitButton.textContent = "Iniciar aplicativo";
  input.focus();
});
