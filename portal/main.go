package main

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"crypto/tls"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"html/template"
	"io"
	"log"
	"math/big"
	"net"
	"net/http"
	"net/http/httputil"
	"net/mail"
	"net/smtp"
	"net/url"
	"os"
	"os/signal"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"time"
)

const (
	pinTTL       = 10 * time.Minute
	pinCooldown  = time.Minute
	sessionTTL   = 12 * time.Hour
	maxPinTries  = 5
	maxBodyBytes = 8192
	cookieName   = "pliik_session"
)

type config struct {
	Addr            string
	CodeServerURL   *url.URL
	UsersFile       string
	ProjectsFile    string
	ProjectsDir     string
	CredentialsFile string
	AdminEmail      string
	SMTPAddr        string
	SMTPFrom        string
	SMTPUser        string
	SMTPPassword    string
}

type user struct {
	Email     string    `json:"email"`
	CreatedAt time.Time `json:"created_at"`
}

type userStore struct {
	mu    sync.Mutex
	path  string
	users map[string]user
}

type pinChallenge struct {
	digest    [sha256.Size]byte
	expiresAt time.Time
	attempts  int
}

type loginSession struct {
	email     string
	expiresAt time.Time
}

type rateWindow struct {
	startedAt time.Time
	count     int
}

type app struct {
	cfg       config
	users     *userStore
	projects  *projectStore
	proxy     *httputil.ReverseProxy
	mu        sync.Mutex
	pins      map[string]pinChallenge
	sessions  map[string]loginSession
	sentAt    map[string]time.Time
	rateLimit map[string]rateWindow
	sendPIN   func(string, string) error
	validatePAT func(string) (string, error)
	cloneRepo func(context.Context, string, string, string) error
}

type loginPage struct {
	Step    string
	Email   string
	Notice  string
	Error   string
	SMTPSet bool
}

var loginTemplate = template.Must(template.New("login").Parse(`<!doctype html>
<html lang="pt-BR"><head>
  <meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
  <meta name="color-scheme" content="light"><title>Pliik Portal</title>
  <style>
    :root{font-family:"Avenir Next",Avenir,"Segoe UI",sans-serif;color:#172f2b;background:#edf2eb}*{box-sizing:border-box}
    body{min-height:100vh;margin:0;display:grid;place-items:center;padding:28px;background-color:#edf2eb;background-image:linear-gradient(rgba(34,79,67,.045) 1px,transparent 1px),linear-gradient(90deg,rgba(34,79,67,.045) 1px,transparent 1px);background-size:32px 32px}
    main{width:min(100%,980px);min-height:530px;display:grid;grid-template-columns:1.05fr .95fr;overflow:hidden;background:#fffefa;border:1px solid #d5ded4;box-shadow:0 24px 70px rgba(25,55,45,.12)}
    .identity{display:flex;flex-direction:column;justify-content:space-between;padding:clamp(30px,6vw,64px);color:#f5f4e9;background:#193d35}.wordmark{font-size:14px;font-weight:750;letter-spacing:.12em}
    .identity h1{max-width:430px;margin:0 0 18px;font-family:Georgia,"Times New Roman",serif;font-size:clamp(38px,5vw,58px);font-weight:400;line-height:1.03}.identity p{max-width:340px;margin:0;color:#c5d6c9;font-size:15px;line-height:1.7}
    .stamp{align-self:flex-start;padding:9px 12px;border:1px solid #648276;color:#d3e2d4;font-size:11px;font-weight:700;letter-spacing:.1em;text-transform:uppercase}
    .form-side{display:flex;align-items:center;padding:clamp(28px,5vw,58px)}form{width:100%}.eyebrow{margin:0 0 12px;color:#a64e3f;font-size:11px;font-weight:800;letter-spacing:.14em;text-transform:uppercase}
    h2{margin:0 0 12px;color:#172f2b;font-family:Georgia,"Times New Roman",serif;font-size:34px;font-weight:400;line-height:1.1}.help{margin:0 0 30px;color:#576c64;font-size:14px;line-height:1.65}
    label{display:block;margin:0 0 8px;color:#25453c;font-size:12px;font-weight:750}input{width:100%;min-height:48px;margin:0 0 18px;padding:0 13px;border:1px solid #bbc9bd;border-radius:2px;background:#fff;color:#172f2b;font:inherit}
    input:focus{outline:3px solid rgba(166,78,63,.22);border-color:#a64e3f}button{width:100%;min-height:48px;border:0;border-radius:2px;background:#a64e3f;color:white;font:inherit;font-size:14px;font-weight:750;cursor:pointer}button:hover{background:#873e32}
    .notice,.error{margin:0 0 18px;padding:12px 13px;border-left:3px solid #437760;background:#edf5ed;color:#25453c;font-size:13px;line-height:1.5}.error{border-color:#a64e3f;background:#fbefec;color:#742f27}.foot{margin:22px 0 0;color:#6a7b73;font-size:12px;line-height:1.55}
    @media(max-width:680px){body{padding:0;background:#fffefa}main{min-height:100vh;grid-template-columns:1fr;border:0;box-shadow:none}.identity{min-height:235px;padding:25px 26px}.identity h1{max-width:300px;font-size:38px}.identity p{display:none}.stamp{margin-top:20px}.form-side{align-items:flex-start;padding:42px 26px}}
  </style>
</head><body><main>
  <section class="identity" aria-label="Pliik"><div class="wordmark">PLIIK / WORKSPACE</div><div><h1>Seu espaço de desenvolvimento.</h1><p>Acesso protegido ao ambiente Code Server desta workstation.</p></div><div class="stamp">Acesso por email</div></section>
  <section class="form-side"><form method="post" action="{{if eq .Step "verify"}}/auth/verify{{else}}/auth/request{{end}}">
    {{if eq .Step "verify"}}<p class="eyebrow">Verificação de email</p><h2>Confirme o acesso</h2><p class="help">Introduza o PIN enviado para <strong>{{.Email}}</strong>. Se ainda não tiver conta, ela será criada depois da confirmação.</p>
      <input type="hidden" name="email" value="{{.Email}}">{{if .Notice}}<p class="notice" role="status">{{.Notice}}</p>{{end}}{{if .Error}}<p class="error" role="alert">{{.Error}}</p>{{end}}
      <label for="pin">PIN de seis dígitos</label><input id="pin" name="pin" type="text" inputmode="numeric" autocomplete="one-time-code" pattern="[0-9]{6}" minlength="6" maxlength="6" required autofocus>
      <button type="submit">Confirmar e entrar</button><p class="foot"><a href="/login">Usar outro email</a></p>
    {{else}}<p class="eyebrow">Portal seguro</p><h2>Entrar na workstation</h2><p class="help">Vamos enviar um PIN temporário para o seu email. Um perfil novo é criado automaticamente depois da confirmação.</p>
      {{if .Error}}<p class="error" role="alert">{{.Error}}</p>{{end}}<label for="email">Email</label><input id="email" name="email" type="email" autocomplete="email" maxlength="254" required autofocus>
      <button type="submit">Enviar PIN</button>{{if not .SMTPSet}}<p class="foot">O envio de email ainda não está configurado pelo administrador.</p>{{end}}
    {{end}}
  </form></section>
</main></body></html>`))

func loadConfig() (config, error) {
	proxyURL, err := url.Parse(envOr("PLIIK_CODE_SERVER_URL", "http://127.0.0.1:18080"))
	if err != nil || (proxyURL.Scheme != "http" && proxyURL.Scheme != "https") || proxyURL.Host == "" {
		return config{}, errors.New("PLIIK_CODE_SERVER_URL must be an HTTP(S) URL")
	}
	configDir, err := os.UserConfigDir()
	if err != nil {
		return config{}, err
	}
	portalDir := filepath.Join(configDir, "pliik-workstation")
	adminEmail := ""
	if raw := os.Getenv("PLIIK_ADMIN_EMAIL"); raw != "" {
		adminEmail, err = normalizeEmail(raw)
		if err != nil {
			return config{}, errors.New("PLIIK_ADMIN_EMAIL must be a valid email address")
		}
	}
	return config{
		Addr:            envOr("PLIIK_PORTAL_ADDR", "127.0.0.1:8080"),
		CodeServerURL:   proxyURL,
		UsersFile:       envOr("PLIIK_USERS_FILE", filepath.Join(portalDir, "portal-users.json")),
		ProjectsFile:    envOr("PLIIK_PROJECTS_FILE", filepath.Join(portalDir, "projects.json")),
		ProjectsDir:     envOr("PLIIK_PROJECTS_DIR", filepath.Join(os.Getenv("HOME"), "pliik-workstation", "projects")),
		CredentialsFile: envOr("PLIIK_GIT_CREDENTIALS_FILE", filepath.Join(portalDir, "git-credentials")),
		AdminEmail:      adminEmail,
		SMTPAddr:        os.Getenv("PLIIK_SMTP_ADDR"),
		SMTPFrom:        os.Getenv("PLIIK_SMTP_FROM"),
		SMTPUser:        os.Getenv("PLIIK_SMTP_USER"),
		SMTPPassword:    os.Getenv("PLIIK_SMTP_PASSWORD"),
	}, nil
}

func envOr(key, fallback string) string {
	if value := os.Getenv(key); value != "" {
		return value
	}
	return fallback
}

func newApp(cfg config) (*app, error) {
	users, err := loadUsers(cfg.UsersFile)
	if err != nil {
		return nil, err
	}
	projects, err := loadProjectStore(cfg.ProjectsFile)
	if err != nil {
		return nil, err
	}
	return &app{
		cfg:       cfg,
		users:     users,
		projects:  projects,
		proxy:     httputil.NewSingleHostReverseProxy(cfg.CodeServerURL),
		pins:      make(map[string]pinChallenge),
		sessions:  make(map[string]loginSession),
		sentAt:    make(map[string]time.Time),
		rateLimit: make(map[string]rateWindow),
		sendPIN:   sendEmailPIN(cfg),
		validatePAT: validateGitHubPAT,
		cloneRepo: cloneGitHubRepo,
	}, nil
}

func loadUsers(path string) (*userStore, error) {
	store := &userStore{path: path, users: make(map[string]user)}
	data, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return store, nil
	}
	if err != nil {
		return nil, fmt.Errorf("read portal users: %w", err)
	}
	if err := json.Unmarshal(data, &store.users); err != nil {
		return nil, fmt.Errorf("decode portal users: %w", err)
	}
	if store.users == nil {
		store.users = make(map[string]user)
	}
	return store, nil
}

func (s *userStore) create(email string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if _, exists := s.users[email]; exists {
		return nil
	}
	s.users[email] = user{Email: email, CreatedAt: time.Now().UTC()}
	if err := writeJSONPrivate(s.path, s.users); err != nil {
		delete(s.users, email)
		return err
	}
	return nil
}

func (s *userStore) list() []user {
	s.mu.Lock()
	defer s.mu.Unlock()
	result := make([]user, 0, len(s.users))
	for _, entry := range s.users {
		result = append(result, entry)
	}
	return result
}

func writeJSONPrivate(path string, value any) error {
	if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
		return err
	}
	data, err := json.MarshalIndent(value, "", "  ")
	if err != nil {
		return err
	}
	temp, err := os.CreateTemp(filepath.Dir(path), ".pliik-*.tmp")
	if err != nil {
		return err
	}
	tempName := temp.Name()
	defer os.Remove(tempName)
	if err := temp.Chmod(0600); err != nil {		_ = temp.Close()
		return err
	}
	if _, err := temp.Write(data); err != nil {		_ = temp.Close()
		return err
	}
	if err := temp.Sync(); err != nil {		_ = temp.Close()
		return err
	}
	if err := temp.Close(); err != nil {
		return err
	}
	return os.Rename(tempName, path)
}

func (a *app) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	if r.URL.Path == "/healthz" {
		if r.Method != http.MethodGet {
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}
		w.Header().Set("Content-Type", "text/plain; charset=utf-8")
		_, _ = io.WriteString(w, "ok\n")
		return
	}
	switch r.URL.Path {
	case "/login":
		a.renderLogin(w, http.StatusOK, loginPage{SMTPSet: a.smtpConfigured()})
		return
	case "/auth/request":
		a.requestPIN(w, r)
		return
	case "/auth/verify":
		a.verifyPIN(w, r)
		return
	case "/logout":
		a.logout(w, r)
		return
	case "/portal":
		if email, ok := a.sessionEmail(r); ok {
			a.renderPortalHome(w, email)
		} else {
			a.renderLogin(w, http.StatusOK, loginPage{SMTPSet: a.smtpConfigured()})
		}
		return
	}
	if strings.HasPrefix(r.URL.Path, "/admin") {
		a.handleAdmin(w, r)
		return
	}
	if _, ok := a.sessionEmail(r); !ok {
		if r.Method != http.MethodGet && r.Method != http.MethodHead {
			http.Error(w, "authentication required", http.StatusUnauthorized)
			return
		}
		a.renderLogin(w, http.StatusOK, loginPage{SMTPSet: a.smtpConfigured()})
		return
	}
	if r.URL.Path == "/" && r.URL.Query().Get("folder") == "" {
		if folder := a.projects.defaultFolder(); folder != "" {
			query := r.URL.Query()
			query.Set("folder", "/home/coder/project/"+folder)
			r.URL.RawQuery = query.Encode()
		}
	}
	a.proxy.ErrorHandler = func(w http.ResponseWriter, r *http.Request, err error) {
		log.Printf("Code Server proxy unavailable: %v", err)
		http.Error(w, "Code Server is unavailable", http.StatusBadGateway)
	}
	a.proxy.ServeHTTP(w, r)
}

func (a *app) requestPIN(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	if !a.sameOrigin(r) {
		http.Error(w, "invalid request origin", http.StatusForbidden)
		return
	}
	if !a.allow("request:"+clientIP(r), 10, 15*time.Minute) {
		http.Error(w, "too many requests", http.StatusTooManyRequests)
		return
	}
	r.Body = http.MaxBytesReader(w, r.Body, maxBodyBytes)
	if err := r.ParseForm(); err != nil {
		a.renderLogin(w, http.StatusBadRequest, loginPage{Error: "Pedido inválido.", SMTPSet: a.smtpConfigured()})
		return
	}
	email, err := normalizeEmail(r.FormValue("email"))
	if err != nil {
		a.renderLogin(w, http.StatusBadRequest, loginPage{Error: "Introduza um email válido.", SMTPSet: a.smtpConfigured()})
		return
	}
	if !a.smtpConfigured() {
		a.renderLogin(w, http.StatusServiceUnavailable, loginPage{Email: email, Error: "O envio de PIN não está configurado. Contacte o administrador.", SMTPSet: false})
		return
	}
	a.mu.Lock()
	if sent, ok := a.sentAt[email]; ok && time.Since(sent) < pinCooldown {
		a.mu.Unlock()
		a.renderLogin(w, http.StatusTooManyRequests, loginPage{Email: email, Error: "Aguarde um minuto antes de pedir outro PIN.", SMTPSet: true})
		return
	}
	a.sentAt[email] = time.Now()
	a.mu.Unlock()
	pin, err := generatePIN()
	if err != nil {
		a.clearSentAt(email)
		log.Printf("generate portal PIN: %v", err)
		a.renderLogin(w, http.StatusInternalServerError, loginPage{Email: email, Error: "Não foi possível gerar o PIN. Tente novamente.", SMTPSet: true})
		return
	}
	if err := a.sendPIN(email, pin); err != nil {
		a.clearSentAt(email)
		log.Printf("send portal PIN: %v", err)
		a.renderLogin(w, http.StatusBadGateway, loginPage{Email: email, Error: "Não foi possível enviar o PIN. Verifique a configuração de email e tente novamente.", SMTPSet: true})
		return
	}
	a.mu.Lock()
	a.pins[email] = pinChallenge{digest: pinDigest(email, pin), expiresAt: time.Now().Add(pinTTL)}
	a.mu.Unlock()
	a.renderLogin(w, http.StatusOK, loginPage{Step: "verify", Email: email, Notice: "Se este endereço puder receber email, o PIN foi enviado. É válido por 10 minutos.", SMTPSet: true})
}

func (a *app) verifyPIN(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	if !a.sameOrigin(r) {
		http.Error(w, "invalid request origin", http.StatusForbidden)
		return
	}
	if !a.allow("verify:"+clientIP(r), 20, 15*time.Minute) {
		http.Error(w, "too many requests", http.StatusTooManyRequests)
		return
	}
	r.Body = http.MaxBytesReader(w, r.Body, maxBodyBytes)
	if err := r.ParseForm(); err != nil {
		a.renderLogin(w, http.StatusBadRequest, loginPage{Error: "Pedido inválido.", SMTPSet: a.smtpConfigured()})
		return
	}
	email, err := normalizeEmail(r.FormValue("email"))
	if err != nil {
		a.renderLogin(w, http.StatusUnauthorized, loginPage{Error: "PIN inválido ou expirado.", SMTPSet: a.smtpConfigured()})
		return
	}
	code := r.FormValue("pin")
	if len(code) != 6 || !allDigits(code) {
		a.renderLogin(w, http.StatusUnauthorized, loginPage{Step: "verify", Email: email, Error: "PIN inválido ou expirado.", SMTPSet: a.smtpConfigured()})
		return
	}
	a.mu.Lock()
	challenge, ok := a.pins[email]
	if !ok || time.Now().After(challenge.expiresAt) || challenge.attempts >= maxPinTries {
		delete(a.pins, email)
		a.mu.Unlock()
		a.renderLogin(w, http.StatusUnauthorized, loginPage{Email: email, Error: "PIN inválido ou expirado. Peça um novo PIN.", SMTPSet: a.smtpConfigured()})
		return
	}
	digest := pinDigest(email, code)
	if subtle.ConstantTimeCompare(challenge.digest[:], digest[:]) != 1 {
		challenge.attempts++
		if challenge.attempts >= maxPinTries {
			delete(a.pins, email)
		} else {
			a.pins[email] = challenge
		}
		a.mu.Unlock()
		a.renderLogin(w, http.StatusUnauthorized, loginPage{Step: "verify", Email: email, Error: "PIN inválido ou expirado.", SMTPSet: a.smtpConfigured()})
		return
	}
	delete(a.pins, email)
	a.mu.Unlock()
	if err := a.users.create(email); err != nil {
		log.Printf("save portal user: %v", err)
		a.renderLogin(w, http.StatusInternalServerError, loginPage{Email: email, Error: "Não foi possível criar o perfil. Tente novamente.", SMTPSet: a.smtpConfigured()})
		return
	}
	token, err := randomToken(32)
	if err != nil {
		log.Printf("create portal session: %v", err)
		http.Error(w, "could not create session", http.StatusInternalServerError)
		return
	}
	expires := time.Now().Add(sessionTTL)
	a.mu.Lock()
	a.sessions[token] = loginSession{email: email, expiresAt: expires}
	a.mu.Unlock()
	http.SetCookie(w, &http.Cookie{Name: cookieName, Value: token, Path: "/", Expires: expires, MaxAge: int(sessionTTL.Seconds()), HttpOnly: true, SameSite: http.SameSiteLaxMode})
	http.Redirect(w, r, "/portal", http.StatusSeeOther)
}

func (a *app) logout(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	if !a.sameOrigin(r) {
		http.Error(w, "invalid request origin", http.StatusForbidden)
		return
	}
	if cookie, err := r.Cookie(cookieName); err == nil {
		a.mu.Lock()
		delete(a.sessions, cookie.Value)
		a.mu.Unlock()
	}
	http.SetCookie(w, &http.Cookie{Name: cookieName, Value: "", Path: "/", MaxAge: -1, HttpOnly: true, SameSite: http.SameSiteLaxMode})
	http.Redirect(w, r, "/login", http.StatusSeeOther)
}

func (a *app) sessionEmail(r *http.Request) (string, bool) {
	cookie, err := r.Cookie(cookieName)
	if err != nil {
		return "", false
	}
	a.mu.Lock()
	defer a.mu.Unlock()
	entry, ok := a.sessions[cookie.Value]
	if !ok {
		return "", false
	}
	if time.Now().After(entry.expiresAt) {
		delete(a.sessions, cookie.Value)
		return "", false
	}
	return entry.email, true
}

func (a *app) renderLogin(w http.ResponseWriter, status int, data loginPage) {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("X-Content-Type-Options", "nosniff")
	w.Header().Set("Referrer-Policy", "no-referrer")
	w.Header().Set("Content-Security-Policy", "default-src 'none'; style-src 'unsafe-inline'; form-action 'self'; base-uri 'none'; frame-ancestors 'none'")
	w.WriteHeader(status)
	if err := loginTemplate.Execute(w, data); err != nil {
		log.Printf("render portal login: %v", err)
	}
}

func (a *app) allow(key string, max int, window time.Duration) bool {
	a.mu.Lock()
	defer a.mu.Unlock()
	now := time.Now()
	entry := a.rateLimit[key]
	if now.Sub(entry.startedAt) >= window {
		entry = rateWindow{startedAt: now}
	}
	if entry.count >= max {
		a.rateLimit[key] = entry
		return false
	}
	entry.count++
	a.rateLimit[key] = entry
	if len(a.rateLimit) > 2048 {
		for oldKey, oldEntry := range a.rateLimit {
			if now.Sub(oldEntry.startedAt) >= window {
				delete(a.rateLimit, oldKey)
			}
		}
	}
	return true
}

func (a *app) clearSentAt(email string) {
	a.mu.Lock()
	delete(a.sentAt, email)
	a.mu.Unlock()
}

func (a *app) sameOrigin(r *http.Request) bool {
	origin := r.Header.Get("Origin")
	if origin == "" {
		return true
	}
	u, err := url.Parse(origin)
	return err == nil && u.Host != "" && strings.EqualFold(u.Host, r.Host)
}

func (a *app) smtpConfigured() bool {
	return a.cfg.SMTPAddr != "" && a.cfg.SMTPFrom != ""
}

func sendEmailPIN(cfg config) func(string, string) error {
	return func(to, pin string) error {
		host, _, err := net.SplitHostPort(cfg.SMTPAddr)
		if err != nil {
			return fmt.Errorf("PLIIK_SMTP_ADDR must be host:port: %w", err)
		}
		from, err := mail.ParseAddress(cfg.SMTPFrom)
		if err != nil || strings.ContainsAny(from.Address, "\r\n") {
			return errors.New("PLIIK_SMTP_FROM must be a valid email address")
		}
		conn, err := net.DialTimeout("tcp", cfg.SMTPAddr, 10*time.Second)
		if err != nil {
			return fmt.Errorf("connect to SMTP server: %w", err)
		}
		client, err := smtp.NewClient(conn, host)
		if err != nil {
			_ = conn.Close()
			return fmt.Errorf("start SMTP session: %w", err)
		}
		defer client.Close()
		if ok, _ := client.Extension("STARTTLS"); !ok {
			return errors.New("SMTP server does not advertise STARTTLS")
		}
		if err := client.StartTLS(&tls.Config{ServerName: host, MinVersion: tls.VersionTLS12}); err != nil {
			return fmt.Errorf("start SMTP TLS: %w", err)
		}
		if cfg.SMTPUser != "" {
			if err := client.Auth(smtp.PlainAuth("", cfg.SMTPUser, cfg.SMTPPassword, host)); err != nil {
				return fmt.Errorf("authenticate with SMTP server: %w", err)
			}
		}
		if err := client.Mail(from.Address); err != nil {
			return fmt.Errorf("set SMTP sender: %w", err)
		}
		if err := client.Rcpt(to); err != nil {
			return fmt.Errorf("set SMTP recipient: %w", err)
		}
		body, err := client.Data()
		if err != nil {
			return fmt.Errorf("start SMTP message: %w", err)
		}
		if _, err := fmt.Fprintf(body, "From: <%s>\r\nTo: <%s>\r\nSubject: Pliik access PIN\r\nMIME-Version: 1.0\r\nContent-Type: text/plain; charset=UTF-8\r\n\r\nYour Pliik sign-in PIN is %s. It expires in 10 minutes.\r\n", from.Address, to, pin); err != nil {
			_ = body.Close()
			return fmt.Errorf("write SMTP message: %w", err)
		}
		if err := body.Close(); err != nil {
			return fmt.Errorf("finish SMTP message: %w", err)
		}
		if err := client.Quit(); err != nil {
			return fmt.Errorf("close SMTP session: %w", err)
		}
		return nil
	}
}

func normalizeEmail(raw string) (string, error) {
	address, err := mail.ParseAddress(strings.TrimSpace(raw))
	if err != nil || strings.ContainsAny(address.Address, "\r\n") {
		return "", errors.New("invalid email")
	}
	if len(address.Address) > 254 {
		return "", errors.New("invalid email")
	}
	return strings.ToLower(address.Address), nil
}

func generatePIN() (string, error) {
	n, err := rand.Int(rand.Reader, big.NewInt(1_000_000))
	if err != nil {
		return "", err
	}
	return fmt.Sprintf("%06d", n.Int64()), nil
}

func pinDigest(email, pin string) [sha256.Size]byte {
	return sha256.Sum256([]byte(email + "\x00" + pin))
}

func randomToken(size int) (string, error) {
	data := make([]byte, size)
	if _, err := rand.Read(data); err != nil {
		return "", err
	}
	return hex.EncodeToString(data), nil
}

func allDigits(value string) bool {
	for _, char := range value {
		if char < '0' || char > '9' {
			return false
		}
	}
	return true
}

func clientIP(r *http.Request) string {
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		return r.RemoteAddr
	}
	return host
}

func main() {
	cfg, err := loadConfig()
	if err != nil {
		log.Fatalf("load portal configuration: %v", err)
	}
	a, err := newApp(cfg)
	if err != nil {
		log.Fatalf("initialize portal: %v", err)
	}
	a.proxy.ErrorHandler = func(w http.ResponseWriter, r *http.Request, err error) {
		log.Printf("Code Server proxy unavailable: %v", err)
		http.Error(w, "Code Server is unavailable", http.StatusBadGateway)
	}
	server := &http.Server{Addr: cfg.Addr, Handler: a, ReadHeaderTimeout: 5 * time.Second, IdleTimeout: 2 * time.Minute}
	stopped := make(chan os.Signal, 1)
	signal.Notify(stopped, os.Interrupt, syscall.SIGTERM)
	go func() {
		<-stopped
		ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		_ = server.Shutdown(ctx)
	}()
	log.Printf("Pliik Portal listening on %s", cfg.Addr)
	if err := server.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
		log.Fatalf("portal server: %v", err)
	}
}