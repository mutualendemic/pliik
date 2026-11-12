package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"html/template"
	"io"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"sync"
	"time"
)

type project struct {
	Name       string    `json:"name"`
	Repository string    `json:"repository"`
	CreatedAt  time.Time `json:"created_at"`
}

type projectState struct {
	Projects []project `json:"projects"`
	Default  string    `json:"default_project"`
}

type projectStore struct {
	mu    sync.Mutex
	path  string
	state projectState
}

type portalHomePage struct {
	Email          string
	Admin          bool
	DefaultProject string
}

type githubRepo struct {
	Name     string `json:"name"`
	FullName string `json:"full_name"`
	URL      string `json:"html_url"`
}

type adminPage struct {
	Email           string
	Notice          string
	Error           string
	GitHubConfigured bool
	Projects        []project
	DefaultProject  string
	GitHubRepos     []githubRepo
	Users           []user
}

var (
	projectNamePattern = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._-]{0,62}$`)
	homeTemplate       = template.Must(template.New("home").Parse(`<!doctype html>
<html lang="pt-BR"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>Pliik Portal</title>
<style>
:root{font-family:"Avenir Next",Avenir,"Segoe UI",sans-serif;color:#172f2b;background:#edf2eb}*{box-sizing:border-box}body{margin:0;min-height:100vh;background-image:linear-gradient(rgba(34,79,67,.04) 1px,transparent 1px),linear-gradient(90deg,rgba(34,79,67,.04) 1px,transparent 1px);background-size:32px 32px}.bar{height:64px;display:flex;align-items:center;justify-content:space-between;padding:0 clamp(20px,5vw,70px);background:#193d35;color:#f5f4e9}.mark{font-size:13px;font-weight:800;letter-spacing:.12em}.bar form{margin:0}.bar button{border:1px solid #6c8c7c;background:transparent;color:#fffefa;padding:9px 13px;font:inherit;font-size:12px;cursor:pointer}main{width:min(100% - 40px,1040px);margin:56px auto}.kicker{color:#a64e3f;font-size:11px;font-weight:800;letter-spacing:.14em;text-transform:uppercase}h1{margin:12px 0;font:400 clamp(38px,6vw,58px)/1.05 Georgia,"Times New Roman",serif}.sub{color:#576c64;line-height:1.7}.actions{display:flex;gap:12px;flex-wrap:wrap;margin:32px 0}a.action{display:inline-flex;align-items:center;min-height:48px;padding:0 18px;background:#a64e3f;color:#fff;text-decoration:none;font-weight:750}a.secondary{background:#193d35}.section{max-width:740px;padding:24px 0;border-top:1px solid #bbc9bd}.section h2{margin:0 0 8px;font:400 25px Georgia,"Times New Roman",serif}.section p{color:#576c64;line-height:1.65}.muted{color:#6a7b73;font-size:13px}
</style></head><body><header class="bar"><div class="mark">PLIIK / WORKSPACE</div><form method="post" action="/logout"><button type="submit">Terminar sessão</button></form></header>
<main><p class="kicker">Portal da workstation</p><h1>Olá, {{.Email}}</h1><p class="sub">Acesso autenticado ao ambiente de desenvolvimento.</p>
<div class="actions"><a class="action" href="/{{if .DefaultProject}}?folder=%2Fhome%2Fcoder%2Fproject%2F{{.DefaultProject}}{{end}}">{{if .DefaultProject}}Abrir {{.DefaultProject}}{{else}}Abrir Code Server{{end}}</a>{{if .Admin}}<a class="action secondary" href="/admin">Administração</a>{{end}}</div>
<section class="section"><h2>Projetos</h2>{{if .DefaultProject}}<p>Projeto padrão do VS Code: <strong>{{.DefaultProject}}</strong></p>{{else}}<p>Ainda não há projeto padrão configurado.</p>{{end}}{{if .Admin}}<p class="muted">Clone repositórios GitHub e escolha o projeto inicial na área de administração.</p>{{end}}</section>
</main></body></html>`)),
	adminTemplate = template.Must(template.New("admin").Parse(`<!doctype html>
<html lang="pt-BR"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>Administração Pliik</title>
<style>
:root{font-family:"Avenir Next",Avenir,"Segoe UI",sans-serif;color:#172f2b;background:#edf2eb}*{box-sizing:border-box}body{margin:0;background-image:linear-gradient(rgba(34,79,67,.04) 1px,transparent 1px),linear-gradient(90deg,rgba(34,79,67,.04) 1px,transparent 1px);background-size:32px 32px}.bar{height:64px;display:flex;align-items:center;justify-content:space-between;padding:0 clamp(20px,5vw,70px);background:#193d35;color:#f5f4e9}.bar a{color:inherit;text-decoration:none}.mark{font-size:13px;font-weight:800;letter-spacing:.12em}main{width:min(100% - 40px,960px);margin:42px auto 80px}.kicker{color:#a64e3f;font-size:11px;font-weight:800;letter-spacing:.14em;text-transform:uppercase}h1{margin:10px 0 32px;font:400 clamp(36px,5vw,50px)/1.05 Georgia,"Times New Roman",serif}.section{padding:24px 0;border-top:1px solid #bbc9bd}.section h2{margin:0 0 8px;font:400 24px Georgia,"Times New Roman",serif}.section p{color:#576c64;line-height:1.6}.grid{display:grid;grid-template-columns:1fr 1fr;gap:26px}.field{display:block;margin:16px 0 7px;font-size:12px;font-weight:750}.input{width:100%;min-height:46px;padding:0 12px;border:1px solid #bbc9bd;border-radius:2px;background:#fff;font:inherit}.input:focus{outline:3px solid rgba(166,78,63,.2);border-color:#a64e3f}button,.button{min-height:44px;padding:0 16px;border:0;border-radius:2px;background:#a64e3f;color:#fff;font:inherit;font-size:13px;font-weight:750;cursor:pointer}form button{margin-top:14px}.notice,.error{margin:0 0 18px;padding:12px;border-left:3px solid #437760;background:#edf5ed;font-size:13px}.error{border-color:#a64e3f;background:#fbefec}.row{display:grid;grid-template-columns:minmax(0,1fr) auto;align-items:center;gap:14px;padding:15px 0;border-top:1px solid #d5ded4}.row small{display:block;margin-top:5px;color:#6a7b73;overflow-wrap:anywhere}.users{display:flex;flex-wrap:wrap;gap:8px}.user{padding:7px 10px;border:1px solid #bbc9bd;background:#fff;font-size:12px}.muted{font-size:12px;color:#6a7b73}@media(max-width:680px){.grid{grid-template-columns:1fr}main{margin-top:30px}.row{grid-template-columns:1fr}}
</style></head><body><header class="bar"><a class="mark" href="/portal">PLIIK / ADMIN</a><a href="/portal">Voltar ao portal</a></header>
<main><p class="kicker">Administração autenticada</p><h1>Projetos e acesso GitHub</h1>{{if .Notice}}<p class="notice" role="status">{{.Notice}}</p>{{end}}{{if .Error}}<p class="error" role="alert">{{.Error}}</p>{{end}}
<section class="section"><h2>Credencial GitHub</h2><p>{{if .GitHubConfigured}}PAT configurado no arquivo privado de credenciais. O valor não é exibido.{{else}}Nenhum PAT configurado.{{end}}</p>
<form method="post" action="/admin/github"><label class="field" for="pat">Personal access token</label><input class="input" id="pat" name="pat" type="password" autocomplete="new-password" minlength="10" maxlength="512" required><p class="muted">Use um PAT com apenas os acessos necessários aos repositórios a clonar.</p><button type="submit">Validar e guardar PAT</button></form></section>
<section class="section"><h2>Repositórios do GitHub</h2><p>Selecione um ou mais repositórios da conta autenticada para criar projetos no pi-web.</p>
{{if .GitHubRepos}}<form method="post" action="/admin/repos"><div class="row"><div><label><input type="checkbox" name="select_all" value="yes" onchange="document.querySelectorAll('input[name=\'repos\']').forEach((el)=>{el.checked=this.checked})"> Selecionar todos</label></div><div><button type="submit">Configurar projetos selecionados</button></div></div>
{{range .GitHubRepos}}<label class="row" style="display:flex;align-items:center;gap:12px;padding:10px 0"><input type="checkbox" name="repos" value="{{.FullName}}" checked> <span><strong>{{.Name}}</strong><small style="display:block;color:#6a7b73;overflow-wrap:anywhere">{{.FullName}}</small></span></label>{{end}}<label style="display:block;margin-top:18px"><input name="make_default" type="checkbox" value="yes" checked> Definir o primeiro repositório selecionado como projeto padrão do VS Code</label></form>{{else}}<p class="muted">Guarde um PAT válido para carregar a lista de repositórios da sua conta.</p>{{end}}</section>
<section class="section"><h2>Clonar repositório manual</h2><p>O clone será guardado na pasta compartilhada com o VS Code.</p><form method="post" action="/admin/repos"><div class="grid"><div><label class="field" for="repository">URL HTTPS do GitHub</label><input class="input" id="repository" name="repository" type="url" placeholder="https://github.com/owner/repository"></div><div><label class="field" for="name">Nome da pasta</label><input class="input" id="name" name="name" type="text" placeholder="repository" pattern="[A-Za-z0-9][A-Za-z0-9._-]{0,62}" maxlength="63"></div></div><label><input name="make_default" type="checkbox" value="yes" checked> Definir como projeto padrão do VS Code</label><br><button type="submit">Clonar projeto</button></form></section>
<section class="section"><h2>Projetos configurados</h2>{{if .Projects}}{{range .Projects}}<div class="row"><div><strong>{{.Name}}</strong>{{if eq $.DefaultProject .Name}} <span class="muted">Padrão</span>{{end}}<small>{{.Repository}}</small></div>{{if ne $.DefaultProject .Name}}<form method="post" action="/admin/default"><input type="hidden" name="name" value="{{.Name}}"><button type="submit">Definir padrão</button></form>{{end}}</div>{{end}}{{else}}<p>Nenhum repositório clonado.</p>{{end}}</section>
<section class="section"><h2>Utilizadores verificados</h2><div class="users">{{range .Users}}<span class="user">{{.Email}}</span>{{else}}<span class="muted">Ainda não há utilizadores.</span>{{end}}</div></section>
</main></body></html>`)),
)

func loadProjectStore(path string) (*projectStore, error) {
	store := &projectStore{path: path, state: projectState{Projects: []project{}}}
	data, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return store, nil
	}
	if err != nil {
		return nil, fmt.Errorf("read portal projects: %w", err)
	}
	if err := json.Unmarshal(data, &store.state); err != nil {
		return nil, fmt.Errorf("decode portal projects: %w", err)
	}
	return store, nil
}

func (s *projectStore) list() []project {
	s.mu.Lock()
	defer s.mu.Unlock()
	items := append([]project(nil), s.state.Projects...)
	sort.Slice(items, func(i, j int) bool { return items[i].Name < items[j].Name })
	return items
}

func (s *projectStore) defaultFolder() string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.state.Default
}

func (s *projectStore) snapshot() projectState {
	s.mu.Lock()
	defer s.mu.Unlock()
	return projectState{Projects: append([]project(nil), s.state.Projects...), Default: s.state.Default}
}

func (s *projectStore) add(item project, makeDefault bool) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	for _, current := range s.state.Projects {
		if current.Name == item.Name {
			return errors.New("project name already exists")
		}
	}
	previous := s.state
	s.state.Projects = append(s.state.Projects, item)
	if makeDefault || s.state.Default == "" {
		s.state.Default = item.Name
	}
	if err := writeJSONPrivate(s.path, s.state); err != nil {
		s.state = previous
		return err
	}
	return nil
}

func (s *projectStore) setDefault(name string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	found := false
	for _, item := range s.state.Projects {
		if item.Name == name {
			found = true
			break
		}
	}
	if !found {
		return errors.New("project not found")
	}
	previous := s.state.Default
	s.state.Default = name
	if err := writeJSONPrivate(s.path, s.state); err != nil {
		s.state.Default = previous
		return err
	}
	return nil
}

func (a *app) renderPortalHome(w http.ResponseWriter, email string) {
	state := a.projects.snapshot()
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("X-Content-Type-Options", "nosniff")
	w.Header().Set("Content-Security-Policy", "default-src 'none'; style-src 'unsafe-inline'; form-action 'self'; base-uri 'none'; frame-ancestors 'none'")
	if err := homeTemplate.Execute(w, portalHomePage{Email: email, Admin: a.isAdmin(email), DefaultProject: state.Default}); err != nil {
		http.Error(w, "could not render portal", http.StatusInternalServerError)
	}
}

func (a *app) isAdmin(email string) bool {
	return a.cfg.AdminEmail != "" && strings.EqualFold(email, a.cfg.AdminEmail)
}

func (a *app) handleAdmin(w http.ResponseWriter, r *http.Request) {
	email, ok := a.sessionEmail(r)
	if !ok {
		a.renderLogin(w, http.StatusUnauthorized, loginPage{SMTPSet: a.smtpConfigured()})
		return
	}
	if !a.isAdmin(email) {
		http.Error(w, "administrator access required", http.StatusForbidden)
		return
	}
	if r.URL.Path == "/admin" && r.Method == http.MethodGet {
		a.renderAdmin(w, http.StatusOK, adminPage{Email: email})
		return
	}
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	if !a.sameOrigin(r) {
		http.Error(w, "invalid request origin", http.StatusForbidden)
		return
	}
	r.Body = http.MaxBytesReader(w, r.Body, maxBodyBytes)
	if err := r.ParseForm(); err != nil {
		a.renderAdmin(w, http.StatusBadRequest, adminPage{Email: email, Error: "Pedido inválido."})
		return
	}
	switch r.URL.Path {
	case "/admin/github":
		a.saveGitHubPAT(w, r, email)
	case "/admin/repos":
		a.cloneProject(w, r, email)
	case "/admin/default":
		if err := a.projects.setDefault(r.FormValue("name")); err != nil {
			a.renderAdmin(w, http.StatusBadRequest, adminPage{Email: email, Error: "Não foi possível definir esse projeto como padrão."})
			return
		}
		a.renderAdmin(w, http.StatusOK, adminPage{Email: email, Notice: "Projeto padrão atualizado."})
	default:
		http.NotFound(w, r)
	}
}

func (a *app) renderAdmin(w http.ResponseWriter, status int, data adminPage) {
	data.GitHubConfigured = hasGitHubCredential(a.cfg.CredentialsFile)
	data.Projects = a.projects.list()
	data.DefaultProject = a.projects.defaultFolder()
	if data.GitHubConfigured {
		if repos, err := listGitHubRepositories(a.cfg.CredentialsFile); err == nil {
			data.GitHubRepos = repos
		}
	}
	data.Users = a.users.list()
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("X-Content-Type-Options", "nosniff")
	w.Header().Set("Referrer-Policy", "no-referrer")
	w.Header().Set("Content-Security-Policy", "default-src 'none'; style-src 'unsafe-inline'; form-action 'self'; base-uri 'none'; frame-ancestors 'none'")
	w.WriteHeader(status)
	if err := adminTemplate.Execute(w, data); err != nil {
		fmt.Fprintln(w, "Could not render administration page")
	}
}

func (a *app) saveGitHubPAT(w http.ResponseWriter, r *http.Request, email string) {
	token := strings.TrimSpace(r.FormValue("pat"))
	if len(token) < 10 || len(token) > 512 || strings.ContainsAny(token, "\r\n\x00") {
		a.renderAdmin(w, http.StatusBadRequest, adminPage{Email: email, Error: "PAT inválido."})
		return
	}
	if _, err := a.validatePAT(token); err != nil {
		a.renderAdmin(w, http.StatusBadGateway, adminPage{Email: email, Error: "O GitHub não validou o PAT. Confirme o token e as permissões."})
		return
	}
	if err := storeGitHubCredential(a.cfg.CredentialsFile, token); err != nil {
		log.Printf("store GitHub credential: %v", err)
		a.renderAdmin(w, http.StatusInternalServerError, adminPage{Email: email, Error: "Não foi possível guardar a credencial."})
		return
	}
	a.renderAdmin(w, http.StatusOK, adminPage{Email: email, Notice: "PAT validado e guardado com permissões privadas."})
}

func (a *app) cloneProject(w http.ResponseWriter, r *http.Request, email string) {
	selected := selectedGitHubRepositories(r.Form)
	if len(selected) > 0 {
		if _, err := a.cloneSelectedProjects(r, email, selected); err != nil {
			a.renderAdmin(w, http.StatusBadRequest, adminPage{Email: email, Error: err.Error()})
			return
		}
		a.renderAdmin(w, http.StatusOK, adminPage{Email: email, Notice: fmt.Sprintf("%d repositórios configurados e prontos para o pi-web.", len(selected))})
		return
	}
	repository, repoName, err := normalizeGitHubRepo(r.FormValue("repository"))
	if err != nil {
		a.renderAdmin(w, http.StatusBadRequest, adminPage{Email: email, Error: "Informe uma URL HTTPS válida de um repositório GitHub."})
		return
	}
	name := strings.TrimSpace(r.FormValue("name"))
	if name == "" {
		name = repoName
	}
	if !projectNamePattern.MatchString(name) || name == "." || name == ".." {
		a.renderAdmin(w, http.StatusBadRequest, adminPage{Email: email, Error: "Nome de pasta inválido."})
		return
	}
	if !hasGitHubCredential(a.cfg.CredentialsFile) {
		a.renderAdmin(w, http.StatusConflict, adminPage{Email: email, Error: "Configure e valide um PAT do GitHub antes de clonar."})
		return
	}
	root, err := filepath.Abs(a.cfg.ProjectsDir)
	if err != nil {
		a.renderAdmin(w, http.StatusInternalServerError, adminPage{Email: email, Error: "Pasta de projetos inválida."})
		return
	}
	if err := os.MkdirAll(root, 0700); err != nil {
		a.renderAdmin(w, http.StatusInternalServerError, adminPage{Email: email, Error: "Não foi possível preparar a pasta de projetos."})
		return
	}
	destination := filepath.Join(root, name)
	if _, err := os.Lstat(destination); err == nil {
		a.renderAdmin(w, http.StatusConflict, adminPage{Email: email, Error: "Já existe uma pasta com esse nome."})
		return
	} else if !errors.Is(err, os.ErrNotExist) {
		a.renderAdmin(w, http.StatusInternalServerError, adminPage{Email: email, Error: "Não foi possível verificar o destino do clone."})
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 10*time.Minute)
	defer cancel()
	if err := a.cloneRepo(ctx, repository, destination, a.cfg.CredentialsFile); err != nil {
		_ = os.RemoveAll(destination)
		log.Printf("clone GitHub repository failed: %v", err)
		a.renderAdmin(w, http.StatusBadGateway, adminPage{Email: email, Error: "O clone falhou. Verifique a URL, o acesso do PAT e a rede."})
		return
	}
	makeDefault := r.FormValue("make_default") == "yes"
	if err := a.projects.add(project{Name: name, Repository: repository, CreatedAt: time.Now().UTC()}, makeDefault); err != nil {
		_ = os.RemoveAll(destination)
		log.Printf("save cloned project: %v", err)
		a.renderAdmin(w, http.StatusInternalServerError, adminPage{Email: email, Error: "O repositório foi clonado, mas não foi possível guardar a configuração."})
		return
	}
	a.renderAdmin(w, http.StatusOK, adminPage{Email: email, Notice: "Repositório clonado e configurado no VS Code."})
}

func selectedGitHubRepositories(values url.Values) []string {
	seen := make(map[string]struct{})
	items := make([]string, 0)
	for _, raw := range values["repos"] {
		for _, part := range strings.FieldsFunc(raw, func(r rune) bool { return r == '\n' || r == '\r' || r == ',' }) {
			clean := strings.TrimSpace(part)
			if clean == "" {
				continue
			}
			if _, ok := seen[clean]; ok {
				continue
			}
			seen[clean] = struct{}{}
			items = append(items, clean)
		}
	}
	if len(items) > 0 {
		return items
	}
	if raw := strings.TrimSpace(values.Get("repositories")); raw != "" {
		for _, part := range strings.FieldsFunc(raw, func(r rune) bool { return r == '\n' || r == '\r' || r == ',' }) {
			clean := strings.TrimSpace(part)
			if clean == "" {
				continue
			}
			if _, ok := seen[clean]; ok {
				continue
			}
			seen[clean] = struct{}{}
			items = append(items, clean)
		}
	}
	return items
}

func (a *app) cloneSelectedProjects(r *http.Request, email string, selected []string) ([]project, error) {
	if !hasGitHubCredential(a.cfg.CredentialsFile) {
		return nil, errors.New("Configure e valide um PAT do GitHub antes de clonar.")
	}
	root, err := filepath.Abs(a.cfg.ProjectsDir)
	if err != nil {
		return nil, errors.New("Pasta de projetos inválida.")
	}
	if err := os.MkdirAll(root, 0700); err != nil {
		return nil, errors.New("Não foi possível preparar a pasta de projetos.")
	}
	makeDefault := r.FormValue("make_default") == "yes"
	created := make([]project, 0, len(selected))
	for index, entry := range selected {
		repositoryURL, repoName, err := normalizeGitHubRepo(entry)
		if err != nil {
			if strings.Contains(entry, "/") {
				repositoryURL = "https://github.com/" + strings.TrimPrefix(strings.TrimSpace(entry), "https://github.com/")
				if !strings.HasSuffix(repositoryURL, ".git") {
					repositoryURL += ".git"
				}
				repositoryURL, repoName, err = normalizeGitHubRepo(repositoryURL)
			}
			if err != nil {
				return nil, fmt.Errorf("repositório inválido: %s", entry)
			}
		}
		name := repoName
		if !projectNamePattern.MatchString(name) || name == "." || name == ".." {
			return nil, fmt.Errorf("nome de pasta inválido para %s", entry)
		}
		destination := filepath.Join(root, name)
		if _, err := os.Lstat(destination); err == nil {
			continue
		} else if !errors.Is(err, os.ErrNotExist) {
			return nil, fmt.Errorf("não foi possível verificar o destino do clone %s", name)
		}
		ctx, cancel := context.WithTimeout(r.Context(), 10*time.Minute)
		if err := a.cloneRepo(ctx, repositoryURL, destination, a.cfg.CredentialsFile); err != nil {
			cancel()
			_ = os.RemoveAll(destination)
			return nil, fmt.Errorf("falha ao clonar %s: %w", entry, err)
		}
		cancel()
		projectEntry := project{Name: name, Repository: repositoryURL, CreatedAt: time.Now().UTC()}
		if err := a.projects.add(projectEntry, makeDefault && len(created) == 0); err != nil {
			_ = os.RemoveAll(destination)
			return nil, fmt.Errorf("falha ao guardar %s: %w", entry, err)
		}
		created = append(created, projectEntry)
		if index == 0 && !makeDefault {
			_ = a.projects.setDefault(name)
		}
	}
	return created, nil
}

func listGitHubRepositories(credentialsFile string) ([]githubRepo, error) {
	credential, err := os.ReadFile(credentialsFile)
	if err != nil {
		return nil, err
	}
	trimmed := strings.TrimSpace(string(credential))
	if trimmed == "" {
		return nil, errors.New("empty GitHub credential")
	}
	lines := strings.Split(trimmed, "\n")
	var token string
	for _, line := range lines {
		parsed, err := url.Parse(line)
		if err == nil && strings.EqualFold(parsed.Hostname(), "github.com") && parsed.User != nil {
			token = parsed.User.Username()
			if token == "x-access-token" {
				if pw, ok := parsed.User.Password(); ok {
					token = pw
				}
			}
			break
		}
	}
	if token == "" {
		return nil, errors.New("PAT not found")
	}
	request, err := http.NewRequest(http.MethodGet, "https://api.github.com/user/repos?per_page=100&sort=updated", nil)
	if err != nil {
		return nil, err
	}
	request.Header.Set("Authorization", "Bearer "+token)
	request.Header.Set("Accept", "application/vnd.github+json")
	request.Header.Set("User-Agent", "Pliik-Portal")
	response, err := (&http.Client{Timeout: 15 * time.Second}).Do(request)
	if err != nil {
		return nil, err
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("GitHub API returned status %d", response.StatusCode)
	}
	var repos []githubRepo
	if err := json.NewDecoder(io.LimitReader(response.Body, 1<<20)).Decode(&repos); err != nil {
		return nil, err
	}
	sort.Slice(repos, func(i, j int) bool { return strings.ToLower(repos[i].FullName) < strings.ToLower(repos[j].FullName) })
	return repos, nil
}

func validateGitHubPAT(token string) (string, error) {
	request, err := http.NewRequest(http.MethodGet, "https://api.github.com/user", nil)
	if err != nil {
		return "", err
	}
	request.Header.Set("Authorization", "Bearer "+token)
	request.Header.Set("Accept", "application/vnd.github+json")
	request.Header.Set("User-Agent", "Pliik-Portal")
	client := &http.Client{Timeout: 15 * time.Second}
	response, err := client.Do(request)
	if err != nil {
		return "", err
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return "", fmt.Errorf("GitHub API returned status %d", response.StatusCode)
	}
	var result struct {
		Login string `json:"login"`
	}
	if err := json.NewDecoder(io.LimitReader(response.Body, 1<<20)).Decode(&result); err != nil {
		return "", err
	}
	if result.Login == "" {
		return "", errors.New("GitHub returned no login")
	}
	return result.Login, nil
}

func storeGitHubCredential(path, token string) error {
	if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
		return err
	}
	lines := []string{}
	if old, err := os.ReadFile(path); err == nil {
		for _, line := range strings.Split(strings.TrimSpace(string(old)), "\n") {
			parsed, parseErr := url.Parse(line)
			if parseErr == nil && strings.EqualFold(parsed.Hostname(), "github.com") {
				continue
			}
			if line != "" {
				lines = append(lines, line)
			}
		}
	} else if !errors.Is(err, os.ErrNotExist) {
		return err
	}
	credentialURL := (&url.URL{Scheme: "https", User: url.UserPassword("x-access-token", token), Host: "github.com"}).String()
	lines = append(lines, credentialURL)
	data := []byte(strings.Join(lines, "\n") + "\n")
	temp, err := os.CreateTemp(filepath.Dir(path), ".git-credentials-*")
	if err != nil {
		return err
	}
	tempName := temp.Name()
	defer os.Remove(tempName)
	if err := temp.Chmod(0600); err != nil {
		_ = temp.Close()
		return err
	}
	if _, err := temp.Write(data); err != nil {
		_ = temp.Close()
		return err
	}
	if err := temp.Sync(); err != nil {
		_ = temp.Close()
		return err
	}
	if err := temp.Close(); err != nil {
		return err
	}
	return os.Rename(tempName, path)
}

func hasGitHubCredential(path string) bool {
	data, err := os.ReadFile(path)
	if err != nil {
		return false
	}
	for _, line := range strings.Split(string(data), "\n") {
		parsed, err := url.Parse(line)
		if err == nil && strings.EqualFold(parsed.Hostname(), "github.com") && parsed.User != nil {
			return true
		}
	}
	return false
}

func normalizeGitHubRepo(raw string) (string, string, error) {
	u, err := url.Parse(strings.TrimSpace(raw))
	if err != nil || u.Scheme != "https" || !strings.EqualFold(u.Host, "github.com") || u.User != nil || u.RawQuery != "" || u.Fragment != "" {
		return "", "", errors.New("repository must be a GitHub HTTPS URL")
	}
	parts := strings.Split(strings.Trim(u.Path, "/"), "/")
	if len(parts) != 2 || !projectNamePattern.MatchString(parts[0]) {
		return "", "", errors.New("repository URL must contain an owner and repository")
	}
	name := strings.TrimSuffix(parts[1], ".git")
	if !projectNamePattern.MatchString(name) || name == "." || name == ".." {
		return "", "", errors.New("invalid repository name")
	}
	return "https://github.com/" + parts[0] + "/" + name + ".git", name, nil
}

func cloneGitHubRepo(ctx context.Context, repository, destination, credentialsFile string) error {
	helper := "store --file=" + credentialsFile
	command := exec.CommandContext(ctx, "git", "-c", "credential.helper="+helper, "clone", "--", repository, destination)
	command.Env = append(os.Environ(), "GIT_TERMINAL_PROMPT=0")
	output, err := command.CombinedOutput()
	if err != nil {
		return fmt.Errorf("git clone: %w: %s", err, strings.TrimSpace(string(output)))
	}
	return nil
}