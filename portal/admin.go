package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"html/template"
	"io"
	"log"
	"net/http"
	"net/mail"
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
	Name                  string    `json:"name"`
	Repository            string    `json:"repository"`
	CreatedAt             time.Time `json:"created_at"`
	PiWebRegistered       bool      `json:"pi_web_registered,omitempty"`
	GitAuthConfigured     bool      `json:"-"`
	GitIdentityConfigured bool      `json:"-"`
}

type projectState struct {
	Projects []project `json:"projects"`
}

type projectStore struct {
	mu    sync.Mutex
	path  string
	state projectState
}

type githubRepo struct {
	Name     string `json:"name"`
	FullName string `json:"full_name"`
	URL      string `json:"html_url"`
}

type adminPage struct {
	Email            string
	CSRFToken        string
	PiWebAvailable   bool
	PiWebURL         string
	Notice           string
	Error            string
	GitHubConfigured bool
	Projects         []project
	GitHubRepos      []githubRepo
}

var (
	projectNamePattern = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._-]{0,62}$`)
	adminTemplate      = template.Must(template.New("admin").Parse(`<!doctype html>
<html lang="pt-BR"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>Administração Pliik</title>
<style>
:root{font-family:"Avenir Next",Avenir,"Segoe UI",sans-serif;color:#172f2b;background:#edf2eb}*{box-sizing:border-box}body{margin:0;background-image:linear-gradient(rgba(34,79,67,.04) 1px,transparent 1px),linear-gradient(90deg,rgba(34,79,67,.04) 1px,transparent 1px);background-size:32px 32px}.bar{height:64px;display:flex;align-items:center;justify-content:space-between;padding:0 clamp(20px,5vw,70px);background:#193d35;color:#f5f4e9}.bar a{color:inherit;text-decoration:none}.mark{font-size:13px;font-weight:800;letter-spacing:.12em}main{width:min(100% - 40px,960px);margin:42px auto 80px}.kicker{color:#a64e3f;font-size:11px;font-weight:800;letter-spacing:.14em;text-transform:uppercase}h1{margin:10px 0 32px;font:400 clamp(36px,5vw,50px)/1.05 Georgia,"Times New Roman",serif}.section{padding:24px 0;border-top:1px solid #bbc9bd}.section h2{margin:0 0 8px;font:400 24px Georgia,"Times New Roman",serif}.section p{color:#576c64;line-height:1.6}.grid{display:grid;grid-template-columns:1fr 1fr;gap:26px}.field{display:block;margin:16px 0 7px;font-size:12px;font-weight:750}.input{width:100%;min-height:46px;padding:0 12px;border:1px solid #bbc9bd;border-radius:2px;background:#fff;font:inherit}.input:focus{outline:3px solid rgba(166,78,63,.2);border-color:#a64e3f}button,.button{min-height:44px;padding:0 16px;border:0;border-radius:2px;background:#a64e3f;color:#fff;font:inherit;font-size:13px;font-weight:750;cursor:pointer}form button{margin-top:14px}.notice,.error{margin:0 0 18px;padding:12px;border-left:3px solid #437760;background:#edf5ed;font-size:13px}.error{border-color:#a64e3f;background:#fbefec}.row{display:grid;grid-template-columns:minmax(0,1fr) auto;align-items:center;gap:14px;padding:15px 0;border-top:1px solid #d5ded4}.row small{display:block;margin-top:5px;color:#6a7b73;overflow-wrap:anywhere}.users{display:flex;flex-wrap:wrap;gap:8px}.user{padding:7px 10px;border:1px solid #bbc9bd;background:#fff;font-size:12px}.muted{font-size:12px;color:#6a7b73}@media(max-width:680px){.grid{grid-template-columns:1fr}main{margin-top:30px}.row{grid-template-columns:1fr}}
</style></head><body><header class="bar"><div class="mark">PLIIK / ADMIN</div></header>
<main><p class="kicker">Administração local</p><h1>Administração do Pi Web</h1>{{if .Notice}}<p class="notice" role="status">{{.Notice}}</p>{{end}}{{if .Error}}<p class="error" role="alert">{{.Error}}</p>{{end}}
<section class="section"><h2>Pi Web</h2><div class="row"><div><strong>Pi Web</strong><small>{{if .PiWebAvailable}}Em execução{{else}}Parado ou indisponível{{end}} · porta 8504</small></div><a class="button" href="{{.PiWebURL}}">Abrir Pi Web</a></div><p class="muted">Os serviços são iniciados e parados com os comandos bin-dev-start e bin-dev-stop.</p></section>
<section class="section"><h2>Credencial GitHub</h2><p>{{if .GitHubConfigured}}PAT configurado no arquivo privado de credenciais. O valor não é exibido.{{else}}Nenhum PAT configurado.{{end}}</p>
<form method="post" action="/admin/github"><input type="hidden" name="_csrf" value="{{.CSRFToken}}"><label class="field" for="pat">Personal access token</label><input class="input" id="pat" name="pat" type="password" autocomplete="new-password" minlength="10" maxlength="512" required><p class="muted">Para clonar e fazer push, o PAT precisa de acesso aos repositórios selecionados e permissão Contents: read and write (além de Metadata: read em tokens fine-grained).</p><button type="submit">Validar e guardar PAT</button></form></section>
<section class="section"><h2>Repositórios do GitHub</h2><p>Selecione repositórios da conta GitHub associada ao PAT para os clonar e adicionar ao Pi Web. A identidade e a autenticação Git serão configuradas localmente em cada projeto para permitir commits e push.</p>
{{if .GitHubRepos}}<form method="post" action="/admin/repos"><input type="hidden" name="_csrf" value="{{.CSRFToken}}"><div class="grid"><div><label class="field" for="git_name">Nome do autor dos commits</label><input class="input" id="git_name" name="git_name" maxlength="100" autocomplete="name" required></div><div><label class="field" for="git_email">E-mail do autor dos commits</label><input class="input" id="git_email" name="git_email" type="email" maxlength="254" autocomplete="email" required></div></div><p class="muted">Estes dados e o helper GitHub são gravados apenas na configuração local de cada repositório. O PAT permanece no arquivo privado do portal e não é copiado para os projetos.</p><div class="row"><div><label><input type="checkbox" name="select_all" value="yes" onchange="document.querySelectorAll('input[name=\'repos\']').forEach((el)=>{el.checked=this.checked})"> Selecionar todos</label></div><div><button type="submit">Configurar projetos selecionados</button></div></div>
{{range .GitHubRepos}}<label class="row" style="display:flex;align-items:center;gap:12px;padding:10px 0"><input type="checkbox" name="repos" value="{{.FullName}}" checked> <span><strong>{{.Name}}</strong><small style="display:block;color:#6a7b73;overflow-wrap:anywhere">{{.FullName}}</small></span></label>{{end}}</form>{{else}}<p class="muted">Guarde um PAT válido para carregar a lista de repositórios da sua conta.</p>{{end}}</section>
<section class="section"><h2>Projetos no Pi Web</h2>{{if .Projects}}{{range .Projects}}<div class="row"><div><strong>{{.Name}}</strong><small>{{.Repository}}</small>{{if .PiWebRegistered}}<small>Registado no Pi Web</small>{{else}}<small>Ainda não registado no Pi Web</small>{{end}}{{if .GitAuthConfigured}}<small>Configuração de autenticação GitHub pronta</small>{{else}}<small>Autenticação GitHub pendente</small>{{end}}{{if .GitIdentityConfigured}}<small>Identidade de commit configurada</small>{{else}}<small>Identidade de commit pendente</small>{{end}}</div>{{if not .PiWebRegistered}}<form method="post" action="/admin/pi-web/register"><input type="hidden" name="_csrf" value="{{$.CSRFToken}}"><input type="hidden" name="name" value="{{.Name}}"><button type="submit">Adicionar ao Pi Web</button></form>{{end}}</div><details><summary>Configurar Git neste projeto</summary><form method="post" action="/admin/git/configure"><input type="hidden" name="_csrf" value="{{$.CSRFToken}}"><input type="hidden" name="name" value="{{.Name}}"><div class="grid"><div><label class="field" for="git_name_{{.Name}}">Nome do autor dos commits</label><input class="input" id="git_name_{{.Name}}" name="git_name" maxlength="100" autocomplete="name" required></div><div><label class="field" for="git_email_{{.Name}}">E-mail do autor dos commits</label><input class="input" id="git_email_{{.Name}}" name="git_email" type="email" maxlength="254" autocomplete="email" required></div></div><p class="muted">Usa o PAT guardado no portal para autenticação GitHub; não é necessário inseri-lo novamente.</p><button type="submit">Configurar Git</button></form></details>{{end}}{{else}}<p>Nenhum repositório clonado.</p>{{end}}</section>
</main></body></html>`))
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

func (s *projectStore) add(item project) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	for _, current := range s.state.Projects {
		if current.Name == item.Name {
			return errors.New("project name already exists")
		}
	}
	previous := s.state
	s.state.Projects = append(s.state.Projects, item)
	if err := writeJSONPrivate(s.path, s.state); err != nil {
		s.state = previous
		return err
	}
	return nil
}

func (s *projectStore) projectByName(name string) (project, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	for _, item := range s.state.Projects {
		if item.Name == name {
			return item, true
		}
	}
	return project{}, false
}

func (s *projectStore) setPiWebRegistered(name string, registered bool) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	for index := range s.state.Projects {
		if s.state.Projects[index].Name != name {
			continue
		}
		previous := s.state.Projects[index].PiWebRegistered
		s.state.Projects[index].PiWebRegistered = registered
		if err := writeJSONPrivate(s.path, s.state); err != nil {
			s.state.Projects[index].PiWebRegistered = previous
			return err
		}
		return nil
	}
	return errors.New("project not found")
}

func (a *app) handleAdmin(w http.ResponseWriter, r *http.Request) {
	email := ""
	if r.URL.Path == "/admin" && r.Method == http.MethodGet {
		a.renderAdmin(w, http.StatusOK, adminPage{Email: email})
		return
	}
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	r.Body = http.MaxBytesReader(w, r.Body, maxBodyBytes)
	if err := r.ParseForm(); err != nil {
		a.renderAdmin(w, http.StatusBadRequest, adminPage{Email: email, Error: "Pedido inválido."})
		return
	}
	origin := r.Header.Get("Origin")
	originMatches := origin != "" && a.sameOrigin(r)
	if !originMatches && !a.validCSRFToken(r.FormValue("_csrf")) {
		originHost := ""
		if parsedOrigin, err := url.Parse(r.Header.Get("Origin")); err == nil {
			originHost = parsedOrigin.Host
		}
		log.Printf("rejected admin request origin: originHost=%q requestHost=%q path=%q", originHost, r.Host, r.URL.Path)
		http.Error(w, "Origem rejeitada: atualize a página e tente novamente.", http.StatusForbidden)
		return
	}
	switch r.URL.Path {
	case "/admin/github":
		a.saveGitHubPAT(w, r, email)
	case "/admin/repos":
		a.cloneProject(w, r, email)
	case "/admin/pi-web/register":
		a.registerProjectInPiWeb(w, r, email)
	case "/admin/git/configure":
		a.configureExistingProjectGit(w, r, email)
	default:
		http.NotFound(w, r)
	}
}

func (a *app) registerProjectInPiWeb(w http.ResponseWriter, r *http.Request, email string) {
	name := r.FormValue("name")
	if !projectNamePattern.MatchString(name) || name == "." || name == ".." {
		a.renderAdmin(w, http.StatusBadRequest, adminPage{Email: email, Error: "Nome de projeto inválido."})
		return
	}
	item, ok := a.projects.projectByName(name)
	if !ok {
		a.renderAdmin(w, http.StatusBadRequest, adminPage{Email: email, Error: "Projeto não encontrado."})
		return
	}
	projectPath, err := filepath.Abs(filepath.Join(a.cfg.ProjectsDir, item.Name))
	if err != nil {
		a.renderAdmin(w, http.StatusBadRequest, adminPage{Email: email, Error: "A pasta do projeto não está disponível."})
		return
	}
	if _, err := os.Stat(projectPath); err != nil {
		a.renderAdmin(w, http.StatusBadRequest, adminPage{Email: email, Error: "A pasta do projeto não está disponível."})
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 10*time.Second)
	defer cancel()
	if _, err := registerPiWebProject(ctx, a.cfg.PiWebURL, projectPath, item.Name); err != nil {
		log.Printf("register project in Pi Web (%s): %v", item.Name, err)
		a.renderAdmin(w, http.StatusBadGateway, adminPage{Email: email, Error: "Não foi possível registar o projeto no Pi Web. Confirme se o serviço está ativo."})
		return
	}
	if err := a.projects.setPiWebRegistered(item.Name, true); err != nil {
		log.Printf("save Pi Web project status (%s): %v", item.Name, err)
		a.renderAdmin(w, http.StatusInternalServerError, adminPage{Email: email, Error: "O projeto foi registado no Pi Web, mas não foi possível guardar o estado no portal."})
		return
	}
	a.renderAdmin(w, http.StatusOK, adminPage{Email: email, Notice: "Projeto adicionado ao Pi Web."})
}

func (a *app) configureExistingProjectGit(w http.ResponseWriter, r *http.Request, email string) {
	name := r.FormValue("name")
	gitName := strings.TrimSpace(r.FormValue("git_name"))
	gitEmail := strings.TrimSpace(r.FormValue("git_email"))
	if err := a.configureExistingProject(name, gitName, gitEmail); err != nil {
		a.renderAdmin(w, http.StatusBadRequest, adminPage{Email: email, Error: err.Error()})
		return
	}
	a.renderAdmin(w, http.StatusOK, adminPage{Email: email, Notice: "Configuração Git atualizada para " + name + "."})
}

func (a *app) configureExistingProject(name, gitName, gitEmail string) error {
	if !projectNamePattern.MatchString(name) || name == "." || name == ".." {
		return errors.New("Nome de projeto inválido.")
	}
	if err := validateGitIdentity(gitName, gitEmail); err != nil {
		return err
	}
	if !hasGitHubCredential(a.cfg.CredentialsFile) {
		return errors.New("Configure e valide um PAT do GitHub antes de configurar o projeto.")
	}
	item, ok := a.projects.projectByName(name)
	if !ok {
		return errors.New("Projeto não encontrado.")
	}
	if _, _, err := normalizeGitHubRepo(item.Repository); err != nil {
		return errors.New("O projeto não possui um endereço HTTPS válido do GitHub.")
	}
	root, err := filepath.Abs(a.cfg.ProjectsDir)
	if err != nil {
		return errors.New("Pasta de projetos inválida.")
	}
	projectPath, err := filepath.Abs(filepath.Join(root, item.Name))
	if err != nil {
		return errors.New("A pasta do projeto não está disponível.")
	}
	relative, err := filepath.Rel(root, projectPath)
	if err != nil || relative != item.Name {
		return errors.New("A pasta do projeto não está disponível.")
	}
	projectInfo, err := os.Lstat(projectPath)
	if err != nil || !projectInfo.IsDir() {
		return errors.New("A pasta do projeto não está disponível.")
	}
	gitInfo, err := os.Lstat(filepath.Join(projectPath, ".git"))
	if err != nil || gitInfo.Mode()&os.ModeSymlink != 0 {
		return errors.New("A pasta do projeto não contém um repositório Git válido.")
	}
	if err := configureClonedRepository(projectPath, a.cfg.CredentialsFile, gitName, gitEmail); err != nil {
		log.Printf("configure Git for existing project (%s): %v", name, err)
		return errors.New("Não foi possível configurar Git neste projeto.")
	}
	return nil
}

func registerPiWebProject(ctx context.Context, base *url.URL, projectPath, name string) (string, error) {
	endpoint := *base
	endpoint.Path = strings.TrimRight(endpoint.Path, "/") + "/api/projects"
	body, err := json.Marshal(map[string]any{"path": projectPath, "name": name, "create": false})
	if err != nil {
		return "", err
	}
	request, err := http.NewRequestWithContext(ctx, http.MethodPost, endpoint.String(), bytes.NewReader(body))
	if err != nil {
		return "", err
	}
	request.Header.Set("Content-Type", "application/json")
	response, err := (&http.Client{Timeout: 10 * time.Second}).Do(request)
	if err != nil {
		return "", err
	}
	defer response.Body.Close()
	responseBody, err := io.ReadAll(io.LimitReader(response.Body, 1<<20))
	if err != nil {
		return "", err
	}
	if response.StatusCode < http.StatusOK || response.StatusCode >= http.StatusMultipleChoices {
		return "", fmt.Errorf("Pi Web returned status %d: %s", response.StatusCode, strings.TrimSpace(string(responseBody)))
	}
	var result struct {
		ID string `json:"id"`
	}
	if len(responseBody) > 0 {
		if err := json.Unmarshal(responseBody, &result); err != nil {
			return "", fmt.Errorf("decode Pi Web response: %w", err)
		}
	}
	return result.ID, nil
}

func (a *app) renderAdmin(w http.ResponseWriter, status int, data adminPage) {
	data.CSRFToken = a.csrfToken
	data.PiWebURL = a.cfg.PiWebURL.String()
	data.PiWebAvailable = serviceAvailable(a.cfg.PiWebURL)
	data.GitHubConfigured = hasGitHubCredential(a.cfg.CredentialsFile)
	data.Projects = a.projects.list()
	for index := range data.Projects {
		projectPath := filepath.Join(a.cfg.ProjectsDir, data.Projects[index].Name)
		data.Projects[index].GitAuthConfigured = gitAuthIsConfigured(projectPath, a.cfg.CredentialsFile)
		data.Projects[index].GitIdentityConfigured = gitIdentityIsConfigured(projectPath)
	}
	if data.GitHubConfigured {
		if repos, err := listGitHubRepositories(a.cfg.CredentialsFile); err == nil {
			data.GitHubRepos = repos
		}
	}
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
	gitName := strings.TrimSpace(r.FormValue("git_name"))
	gitEmail := strings.TrimSpace(r.FormValue("git_email"))
	if err := validateGitIdentity(gitName, gitEmail); err != nil {
		a.renderAdmin(w, http.StatusBadRequest, adminPage{Email: email, Error: err.Error()})
		return
	}
	selected := selectedGitHubRepositories(r.Form)
	if len(selected) == 0 {
		a.renderAdmin(w, http.StatusBadRequest, adminPage{Email: email, Error: "Selecione pelo menos um repositório da lista do GitHub."})
		return
	}
	created, err := a.cloneSelectedProjects(r, email, selected, gitName, gitEmail)
	if err != nil {
		a.renderAdmin(w, http.StatusBadRequest, adminPage{Email: email, Error: err.Error()})
		return
	}
	registered := 0
	for _, item := range created {
		if item.PiWebRegistered {
			registered++
		}
	}
	a.renderAdmin(w, http.StatusOK, adminPage{Email: email, Notice: fmt.Sprintf("%d projetos novos processados; %d registados no Pi Web.", len(created), registered)})
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

func (a *app) cloneSelectedProjects(r *http.Request, email string, selected []string, gitName, gitEmail string) ([]project, error) {
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
	created := make([]project, 0, len(selected))
	for _, entry := range selected {
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
		if err := configureClonedRepository(destination, a.cfg.CredentialsFile, gitName, gitEmail); err != nil {
			_ = os.RemoveAll(destination)
			return nil, fmt.Errorf("falha ao configurar autenticação Git para %s: %w", name, err)
		}
		projectEntry := project{Name: name, Repository: repositoryURL, CreatedAt: time.Now().UTC()}
		if err := a.projects.add(projectEntry); err != nil {
			_ = os.RemoveAll(destination)
			return nil, fmt.Errorf("falha ao guardar %s: %w", entry, err)
		}
		ctx, cancel = context.WithTimeout(r.Context(), 10*time.Second)
		if _, registerErr := registerPiWebProject(ctx, a.cfg.PiWebURL, destination, name); registerErr != nil {
			log.Printf("register selected project in Pi Web (%s): %v", name, registerErr)
		} else {
			projectEntry.PiWebRegistered = true
			if err := a.projects.setPiWebRegistered(name, true); err != nil {
				log.Printf("save Pi Web project status (%s): %v", name, err)
			}
		}
		cancel()
		created = append(created, projectEntry)
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

func validateGitIdentity(name, email string) error {
	if name == "" || len(name) > 100 || strings.ContainsAny(name, "\r\n\x00") {
		return errors.New("Informe um nome de autor válido (até 100 caracteres).")
	}
	if email == "" || len(email) > 254 || strings.ContainsAny(email, "\r\n\x00") {
		return errors.New("Informe um e-mail de autor válido.")
	}
	parsed, err := mail.ParseAddress(email)
	if err != nil || parsed.Address != email {
		return errors.New("Informe um endereço de e-mail válido, sem nome de exibição.")
	}
	return nil
}

func isGitCheckoutPath(repositoryPath string) bool {
	projectInfo, err := os.Lstat(repositoryPath)
	if err != nil || !projectInfo.IsDir() {
		return false
	}
	gitInfo, err := os.Lstat(filepath.Join(repositoryPath, ".git"))
	return err == nil && gitInfo.Mode()&os.ModeSymlink == 0
}

func gitAuthIsConfigured(repositoryPath, credentialsFile string) bool {
	if !isGitCheckoutPath(repositoryPath) || !hasGitHubCredential(credentialsFile) {
		return false
	}
	command := exec.Command("git", "-C", repositoryPath, "config", "--local", "--get-all", "credential.helper")
	output, err := command.Output()
	if err != nil {
		return false
	}
	values := strings.Split(strings.TrimSuffix(string(output), "\n"), "\n")
	want := "store --file=" + shellQuote(credentialsFile)
	return len(values) >= 2 && values[0] == "" && values[len(values)-1] == want
}

func gitIdentityIsConfigured(repositoryPath string) bool {
	if !isGitCheckoutPath(repositoryPath) {
		return false
	}
	nameCommand := exec.Command("git", "-C", repositoryPath, "config", "--local", "--get", "user.name")
	name, err := nameCommand.Output()
	if err != nil {
		return false
	}
	emailCommand := exec.Command("git", "-C", repositoryPath, "config", "--local", "--get", "user.email")
	email, err := emailCommand.Output()
	return err == nil && validateGitIdentity(strings.TrimSpace(string(name)), strings.TrimSpace(string(email))) == nil
}

func configureClonedRepository(repositoryPath, credentialsFile, gitName, gitEmail string) error {
	if err := validateGitIdentity(gitName, gitEmail); err != nil {
		return err
	}
	commands := [][]string{
		{"config", "--local", "--replace-all", "credential.helper", ""},
		{"config", "--local", "--add", "credential.helper", "store --file=" + shellQuote(credentialsFile)},
		{"config", "--local", "user.name", gitName},
		{"config", "--local", "user.email", gitEmail},
	}
	for _, args := range commands {
		command := exec.Command("git", append([]string{"-C", repositoryPath}, args...)...)
		if output, err := command.CombinedOutput(); err != nil {
			return fmt.Errorf("git %s: %w: %s", args[0], err, strings.TrimSpace(string(output)))
		}
	}
	return nil
}

// shellQuote makes the credential-store path one literal argument to Git's helper shell.
func shellQuote(value string) string {
	return "'" + strings.ReplaceAll(value, "'", "'\\''") + "'"
}

func cloneGitHubRepo(ctx context.Context, repository, destination, credentialsFile string) error {
	helper := "store --file=" + shellQuote(credentialsFile)
	command := exec.CommandContext(ctx, "git", "-c", "credential.helper="+helper, "clone", "--", repository, destination)
	command.Env = append(os.Environ(), "GIT_TERMINAL_PROMPT=0")
	output, err := command.CombinedOutput()
	if err != nil {
		return fmt.Errorf("git clone: %w: %s", err, strings.TrimSpace(string(output)))
	}
	return nil
}
