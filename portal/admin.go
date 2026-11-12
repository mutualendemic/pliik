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
	GitHubAccount         string    `json:"github_account,omitempty"`
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

type githubAccount struct {
	Login string `json:"login"`
	Token string `json:"token"`
}

type githubAccountView struct {
	Login string
}

type adminPage struct {
	Email           string
	CSRFToken       string
	PiWebAvailable  bool
	PiWebURL        string
	Notice          string
	Error           string
	GitHubAccounts  []githubAccountView
	SelectedAccount string
	Projects        []project
	GitHubRepos     []githubRepo
}

var (
	projectNamePattern = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._-]{0,62}$`)
	adminTemplate      = template.Must(template.New("admin").Parse(`<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>Pliik Administration</title>
<style>
:root{font-family:"Avenir Next",Avenir,"Segoe UI",sans-serif;color:#172f2b;background:#edf2eb}*{box-sizing:border-box}body{margin:0;background-image:linear-gradient(rgba(34,79,67,.04) 1px,transparent 1px),linear-gradient(90deg,rgba(34,79,67,.04) 1px,transparent 1px);background-size:32px 32px}.bar{height:64px;display:flex;align-items:center;justify-content:space-between;padding:0 clamp(20px,5vw,70px);background:#193d35;color:#f5f4e9}.bar a{color:inherit;text-decoration:none}.mark{font-size:13px;font-weight:800;letter-spacing:.12em}main{width:min(100% - 40px,960px);margin:42px auto 80px}.kicker{color:#a64e3f;font-size:11px;font-weight:800;letter-spacing:.14em;text-transform:uppercase}h1{margin:10px 0 32px;font:400 clamp(36px,5vw,50px)/1.05 Georgia,"Times New Roman",serif}.section{padding:24px 0;border-top:1px solid #bbc9bd}.section h2{margin:0 0 8px;font:400 24px Georgia,"Times New Roman",serif}.section p{color:#576c64;line-height:1.6}.grid{display:grid;grid-template-columns:1fr 1fr;gap:26px}.field{display:block;margin:16px 0 7px;font-size:12px;font-weight:750}.input{width:100%;min-height:46px;padding:0 12px;border:1px solid #bbc9bd;border-radius:2px;background:#fff;font:inherit}.input:focus{outline:3px solid rgba(166,78,63,.2);border-color:#a64e3f}button,.button{min-height:44px;padding:0 16px;border:0;border-radius:2px;background:#a64e3f;color:#fff;font:inherit;font-size:13px;font-weight:750;cursor:pointer}.button{display:inline-flex;align-items:center;justify-content:center;text-align:center;text-decoration:none}form button{margin-top:14px}.notice,.error{margin:0 0 18px;padding:12px;border-left:3px solid #437760;background:#edf5ed;font-size:13px}.error{border-color:#a64e3f;background:#fbefec}.row{display:grid;grid-template-columns:minmax(0,1fr) auto;align-items:center;gap:14px;padding:15px 0;border-top:1px solid #d5ded4}.row small{display:block;margin-top:5px;color:#6a7b73;overflow-wrap:anywhere}.users{display:flex;flex-wrap:wrap;gap:8px}.user{padding:7px 10px;border:1px solid #bbc9bd;background:#fff;font-size:12px}.muted{font-size:12px;color:#6a7b73}@media(max-width:680px){.grid{grid-template-columns:1fr}main{margin-top:30px}.row{grid-template-columns:1fr}}
</style></head><body><header class="bar"><div class="mark">PLIIK / ADMIN</div></header>
<main><p class="kicker">LOCAL ADMINISTRATION</p><h1>Pi Web Administration</h1>{{if .Notice}}<p class="notice" role="status">{{.Notice}}</p>{{end}}{{if .Error}}<p class="error" role="alert">{{.Error}}</p>{{end}}
<section class="section"><h2>Pi Web</h2><div class="row"><div><strong>Pi Web</strong><small>{{if .PiWebAvailable}}Running{{else}}Stopped or unavailable{{end}} · port 8504</small></div><a class="button" href="{{.PiWebURL}}">Open Pi Web</a></div><p class="muted">Start and stop the services with bin-dev-start and bin-dev-stop.</p></section>
<section class="section"><h2>GitHub Credentials</h2>{{if .GitHubAccounts}}<p>PATs stored securely (values are never shown): {{range .GitHubAccounts}}<strong>{{.Login}}</strong> {{end}}</p>{{else}}<p>No PATs configured.</p>{{end}}
<form method="post" action="/admin/github"><input type="hidden" name="_csrf" value="{{.CSRFToken}}"><label class="field" for="pat">Add or update a PAT</label><input class="input" id="pat" name="pat" type="password" autocomplete="new-password" minlength="10" maxlength="512" required><p class="muted">To clone and push, the PAT must have access to the selected repositories and Contents: read and write permission (plus Metadata: read for fine-grained tokens). Adding a PAT for an account replaces its previous PAT; PATs for other accounts are kept separately.</p><button type="submit">Validate and save PAT</button></form></section>
<section class="section"><h2>GitHub Repositories</h2><p>Select an account to list and clone its repositories. Each project is associated with the selected account and uses its PAT for Git.</p>
{{if .GitHubAccounts}}<form method="get" action="/admin"><label class="field" for="account">GitHub account</label><select class="input" id="account" name="account">{{range .GitHubAccounts}}<option value="{{.Login}}" {{if eq .Login $.SelectedAccount}}selected{{end}}>{{.Login}}</option>{{end}}</select><button type="submit">Load repositories</button></form>{{end}}
{{if .GitHubRepos}}<form method="post" action="/admin/repos"><input type="hidden" name="_csrf" value="{{.CSRFToken}}"><input type="hidden" name="account" value="{{.SelectedAccount}}"><div class="grid"><div><label class="field" for="git_name">Commit author name</label><input class="input" id="git_name" name="git_name" maxlength="100" autocomplete="name" required></div><div><label class="field" for="git_email">Commit author email</label><input class="input" id="git_email" name="git_email" type="email" maxlength="254" autocomplete="email" required></div></div><p class="muted">The PAT is not added to project Git configuration; each project uses a private credentials file.</p><div class="row"><div><label><input type="checkbox" name="select_all" value="yes" onchange="document.querySelectorAll('input[name=\'repos\']').forEach((el)=>{el.checked=this.checked})"> Select all</label></div><div><button type="submit">Configure selected projects</button></div></div>
{{range .GitHubRepos}}<label class="row" style="display:flex;align-items:center;gap:12px;padding:10px 0"><input type="checkbox" name="repos" value="{{.FullName}}" checked> <span><strong>{{.Name}}</strong><small style="display:block;color:#6a7b73;overflow-wrap:anywhere">{{.FullName}}</small></span></label>{{end}}</form>{{else if .SelectedAccount}}<p class="muted">Could not load repositories for this account.</p>{{else}}<p class="muted">Save a PAT and select an account to load its repositories.</p>{{end}}</section>
<section class="section"><h2>Projects in Pi Web</h2>{{if .Projects}}{{range .Projects}}<div class="row"><div><strong>{{.Name}}</strong><small>{{.Repository}}</small>{{if .PiWebRegistered}}<small>Registered in Pi Web</small>{{else}}<small>Not registered in Pi Web yet</small>{{end}}{{if .GitAuthConfigured}}<small>GitHub authentication configured</small>{{else}}<small>GitHub authentication pending</small>{{end}}{{if .GitIdentityConfigured}}<small>Commit identity configured</small>{{else}}<small>Commit identity pending</small>{{end}}</div>{{if not .PiWebRegistered}}<form method="post" action="/admin/pi-web/register"><input type="hidden" name="_csrf" value="{{$.CSRFToken}}"><input type="hidden" name="name" value="{{.Name}}"><button type="submit">Add to Pi Web</button></form>{{end}}</div><details><summary>Configure Git for this project</summary>{{$project := .}}<form method="post" action="/admin/git/configure"><input type="hidden" name="_csrf" value="{{$.CSRFToken}}"><input type="hidden" name="name" value="{{$project.Name}}"><label class="field" for="git_account_{{$project.Name}}">GitHub account</label><select class="input" id="git_account_{{$project.Name}}" name="account" required>{{range $.GitHubAccounts}}<option value="{{.Login}}" {{if eq .Login $project.GitHubAccount}}selected{{end}}>{{.Login}}</option>{{end}}</select><div class="grid"><div><label class="field" for="git_name_{{.Name}}">Commit author name</label><input class="input" id="git_name_{{.Name}}" name="git_name" maxlength="100" autocomplete="name" required></div><div><label class="field" for="git_email_{{.Name}}">Commit author email</label><input class="input" id="git_email_{{.Name}}" name="git_email" type="email" maxlength="254" autocomplete="email" required></div></div><p class="muted">The selected account's PAT will be used for this project. You do not need to enter it again.</p><button type="submit">Configure Git</button></form></details>{{end}}{{else}}<p>No repositories cloned.</p>{{end}}</section>
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

func (s *projectStore) updateGitHubAccount(name, account string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	for index := range s.state.Projects {
		if s.state.Projects[index].Name != name {
			continue
		}
		previous := s.state.Projects[index].GitHubAccount
		s.state.Projects[index].GitHubAccount = account
		if err := writeJSONPrivate(s.path, s.state); err != nil {
			s.state.Projects[index].GitHubAccount = previous
			return err
		}
		return nil
	}
	return errors.New("project not found")
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
		a.renderAdmin(w, http.StatusOK, adminPage{Email: email, SelectedAccount: r.URL.Query().Get("account")})
		return
	}
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	r.Body = http.MaxBytesReader(w, r.Body, maxBodyBytes)
	if err := r.ParseForm(); err != nil {
		a.renderAdmin(w, http.StatusBadRequest, adminPage{Email: email, Error: "Invalid request."})
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
		http.Error(w, "Request origin rejected: reload the page and try again.", http.StatusForbidden)
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
		a.renderAdmin(w, http.StatusBadRequest, adminPage{Email: email, Error: "Invalid project name."})
		return
	}
	item, ok := a.projects.projectByName(name)
	if !ok {
		a.renderAdmin(w, http.StatusBadRequest, adminPage{Email: email, Error: "Project not found."})
		return
	}
	projectPath, err := filepath.Abs(filepath.Join(a.cfg.ProjectsDir, item.Name))
	if err != nil {
		a.renderAdmin(w, http.StatusBadRequest, adminPage{Email: email, Error: "The project directory is unavailable."})
		return
	}
	if _, err := os.Stat(projectPath); err != nil {
		a.renderAdmin(w, http.StatusBadRequest, adminPage{Email: email, Error: "The project directory is unavailable."})
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 10*time.Second)
	defer cancel()
	if _, err := registerPiWebProject(ctx, a.cfg.PiWebURL, projectPath, item.Name); err != nil {
		log.Printf("register project in Pi Web (%s): %v", item.Name, err)
		a.renderAdmin(w, http.StatusBadGateway, adminPage{Email: email, Error: "Could not register the project in Pi Web. Check that the service is running."})
		return
	}
	if err := a.projects.setPiWebRegistered(item.Name, true); err != nil {
		log.Printf("save Pi Web project status (%s): %v", item.Name, err)
		a.renderAdmin(w, http.StatusInternalServerError, adminPage{Email: email, Error: "The project was registered in Pi Web, but its status could not be saved in the portal."})
		return
	}
	a.renderAdmin(w, http.StatusOK, adminPage{Email: email, Notice: "Project added to Pi Web."})
}

func (a *app) configureExistingProjectGit(w http.ResponseWriter, r *http.Request, email string) {
	name := r.FormValue("name")
	account := strings.TrimSpace(r.FormValue("account"))
	gitName := strings.TrimSpace(r.FormValue("git_name"))
	gitEmail := strings.TrimSpace(r.FormValue("git_email"))
	if err := a.configureExistingProject(name, account, gitName, gitEmail); err != nil {
		a.renderAdmin(w, http.StatusBadRequest, adminPage{Email: email, Error: err.Error()})
		return
	}
	a.renderAdmin(w, http.StatusOK, adminPage{Email: email, Notice: "Git configuration updated for " + name + "."})
}

func (a *app) configureExistingProject(name, accountLogin, gitName, gitEmail string) error {
	if !projectNamePattern.MatchString(name) || name == "." || name == ".." {
		return errors.New("Invalid project name.")
	}
	if err := validateGitIdentity(gitName, gitEmail); err != nil {
		return err
	}
	account, ok, err := githubAccountFor(a.cfg.AccountsFile, accountLogin)
	if err != nil || !ok {
		return errors.New("Select a GitHub account with a valid PAT before configuring the project.")
	}
	item, ok := a.projects.projectByName(name)
	if !ok {
		return errors.New("Project not found.")
	}
	if _, _, err := normalizeGitHubRepo(item.Repository); err != nil {
		return errors.New("The project does not have a valid GitHub HTTPS URL.")
	}
	root, err := filepath.Abs(a.cfg.ProjectsDir)
	if err != nil {
		return errors.New("Invalid projects directory.")
	}
	projectPath, err := filepath.Abs(filepath.Join(root, item.Name))
	if err != nil {
		return errors.New("The project directory is unavailable.")
	}
	relative, err := filepath.Rel(root, projectPath)
	if err != nil || relative != item.Name {
		return errors.New("The project directory is unavailable.")
	}
	projectInfo, err := os.Lstat(projectPath)
	if err != nil || !projectInfo.IsDir() {
		return errors.New("The project directory is unavailable.")
	}
	gitInfo, err := os.Lstat(filepath.Join(projectPath, ".git"))
	if err != nil || gitInfo.Mode()&os.ModeSymlink != 0 {
		return errors.New("The project directory does not contain a valid Git repository.")
	}
	credentialPath, err := projectCredentialPath(a.cfg.CredentialsFile, item.Repository)
	if err != nil {
		return errors.New("Could not prepare the project's credentials file.")
	}
	if err := storeGitHubCredential(credentialPath, account.Token); err != nil {
		return errors.New("Could not save the project's credential.")
	}
	if err := configureClonedRepository(projectPath, credentialPath, gitName, gitEmail); err != nil {
		log.Printf("configure Git for existing project (%s): %v", name, err)
		return errors.New("Could not configure Git for this project.")
	}
	return a.projects.updateGitHubAccount(name, account.Login)
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
	accounts, err := loadGitHubAccounts(a.cfg.AccountsFile)
	if err == nil {
		for _, account := range accounts {
			data.GitHubAccounts = append(data.GitHubAccounts, githubAccountView{Login: account.Login})
		}
	}
	if data.SelectedAccount == "" && len(accounts) > 0 {
		data.SelectedAccount = accounts[0].Login
	}
	data.Projects = a.projects.list()
	for index := range data.Projects {
		projectPath := filepath.Join(a.cfg.ProjectsDir, data.Projects[index].Name)
		credentialPath := a.cfg.CredentialsFile
		if data.Projects[index].GitHubAccount != "" {
			if scopedPath, pathErr := projectCredentialPath(a.cfg.CredentialsFile, data.Projects[index].Repository); pathErr == nil {
				credentialPath = scopedPath
			}
		}
		data.Projects[index].GitAuthConfigured = gitAuthIsConfigured(projectPath, credentialPath)
		data.Projects[index].GitIdentityConfigured = gitIdentityIsConfigured(projectPath)
	}
	for _, account := range accounts {
		if account.Login != data.SelectedAccount {
			continue
		}
		if repos, listErr := listGitHubRepositories(account.Token); listErr == nil {
			data.GitHubRepos = repos
		}
		break
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
		a.renderAdmin(w, http.StatusBadRequest, adminPage{Email: email, Error: "Invalid PAT."})
		return
	}
	login, err := a.validatePAT(token)
	if err != nil {
		a.renderAdmin(w, http.StatusBadGateway, adminPage{Email: email, Error: "GitHub could not validate the PAT. Check the token and its permissions."})
		return
	}
	if err := saveGitHubAccount(a.cfg.AccountsFile, githubAccount{Login: login, Token: token}); err != nil {
		log.Printf("store GitHub account: %v", err)
		a.renderAdmin(w, http.StatusInternalServerError, adminPage{Email: email, Error: "Could not save the credential."})
		return
	}
	if err := a.updateProjectCredentials(login, token); err != nil {
		log.Printf("update project credentials for GitHub account %s: %v", login, err)
		a.renderAdmin(w, http.StatusOK, adminPage{Email: email, SelectedAccount: login, Notice: "PAT saved for @" + login + "; some projects need to be reconfigured."})
		return
	}
	a.renderAdmin(w, http.StatusOK, adminPage{Email: email, SelectedAccount: login, Notice: "PAT validated and saved for @" + login + "."})
}

func (a *app) updateProjectCredentials(accountLogin, token string) error {
	for _, item := range a.projects.list() {
		if !strings.EqualFold(item.GitHubAccount, accountLogin) {
			continue
		}
		path, err := projectCredentialPath(a.cfg.CredentialsFile, item.Repository)
		if err != nil {
			return err
		}
		if err := storeGitHubCredential(path, token); err != nil {
			return err
		}
	}
	return nil
}

func (a *app) cloneProject(w http.ResponseWriter, r *http.Request, email string) {
	gitName := strings.TrimSpace(r.FormValue("git_name"))
	gitEmail := strings.TrimSpace(r.FormValue("git_email"))
	if err := validateGitIdentity(gitName, gitEmail); err != nil {
		a.renderAdmin(w, http.StatusBadRequest, adminPage{Email: email, Error: err.Error()})
		return
	}
	selected := selectedGitHubRepositories(r.Form)
	account := strings.TrimSpace(r.FormValue("account"))
	if len(selected) == 0 {
		a.renderAdmin(w, http.StatusBadRequest, adminPage{Email: email, Error: "Select at least one repository from the GitHub list."})
		return
	}
	created, err := a.cloneSelectedProjects(r, email, account, selected, gitName, gitEmail)
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
	a.renderAdmin(w, http.StatusOK, adminPage{Email: email, Notice: fmt.Sprintf("%d new projects processed; %d registered in Pi Web.", len(created), registered)})
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

func (a *app) cloneSelectedProjects(r *http.Request, email, accountLogin string, selected []string, gitName, gitEmail string) ([]project, error) {
	account, ok, err := githubAccountFor(a.cfg.AccountsFile, accountLogin)
	if err != nil || !ok {
		return nil, errors.New("Select a GitHub account with a valid PAT before cloning.")
	}
	root, err := filepath.Abs(a.cfg.ProjectsDir)
	if err != nil {
		return nil, errors.New("Invalid projects directory.")
	}
	if err := os.MkdirAll(root, 0700); err != nil {
		return nil, errors.New("Could not prepare the projects directory.")
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
				return nil, fmt.Errorf("invalid repository: %s", entry)
			}
		}
		name := repoName
		if !projectNamePattern.MatchString(name) || name == "." || name == ".." {
			return nil, fmt.Errorf("invalid directory name for %s", entry)
		}
		destination := filepath.Join(root, name)
		if _, err := os.Lstat(destination); err == nil {
			continue
		} else if !errors.Is(err, os.ErrNotExist) {
			return nil, fmt.Errorf("could not verify the clone destination for %s", name)
		}
		credentialPath, err := projectCredentialPath(a.cfg.CredentialsFile, repositoryURL)
		if err != nil {
			return nil, fmt.Errorf("could not prepare credentials for %s", name)
		}
		if err := storeGitHubCredential(credentialPath, account.Token); err != nil {
			return nil, fmt.Errorf("could not save credentials for %s", name)
		}
		ctx, cancel := context.WithTimeout(r.Context(), 10*time.Minute)
		if err := a.cloneRepo(ctx, repositoryURL, destination, credentialPath); err != nil {
			cancel()
			_ = os.RemoveAll(destination)
			return nil, fmt.Errorf("failed to clone %s: %w", entry, err)
		}
		cancel()
		if err := configureClonedRepository(destination, credentialPath, gitName, gitEmail); err != nil {
			_ = os.RemoveAll(destination)
			return nil, fmt.Errorf("failed to configure Git authentication for %s: %w", name, err)
		}
		projectEntry := project{Name: name, Repository: repositoryURL, GitHubAccount: account.Login, CreatedAt: time.Now().UTC()}
		if err := a.projects.add(projectEntry); err != nil {
			_ = os.RemoveAll(destination)
			return nil, fmt.Errorf("failed to save %s: %w", entry, err)
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

func listGitHubRepositories(token string) ([]githubRepo, error) {
	if strings.TrimSpace(token) == "" {
		return nil, errors.New("empty GitHub credential")
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

func loadGitHubAccounts(path string) ([]githubAccount, error) {
	data, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return []githubAccount{}, nil
	}
	if err != nil {
		return nil, err
	}
	var accounts []githubAccount
	if err := json.Unmarshal(data, &accounts); err != nil {
		return nil, fmt.Errorf("decode GitHub accounts: %w", err)
	}
	return accounts, nil
}

func saveGitHubAccount(path string, account githubAccount) error {
	accounts, err := loadGitHubAccounts(path)
	if err != nil {
		return err
	}
	updated := false
	for index := range accounts {
		if strings.EqualFold(accounts[index].Login, account.Login) {
			accounts[index] = account
			updated = true
			break
		}
	}
	if !updated {
		accounts = append(accounts, account)
	}
	sort.Slice(accounts, func(i, j int) bool { return strings.ToLower(accounts[i].Login) < strings.ToLower(accounts[j].Login) })
	return writeJSONPrivate(path, accounts)
}

func githubAccountFor(path, login string) (githubAccount, bool, error) {
	accounts, err := loadGitHubAccounts(path)
	if err != nil {
		return githubAccount{}, false, err
	}
	for _, account := range accounts {
		if strings.EqualFold(account.Login, login) {
			return account, true, nil
		}
	}
	return githubAccount{}, false, nil
}

func projectCredentialPath(credentialsFile, repository string) (string, error) {
	_, repoName, err := normalizeGitHubRepo(repository)
	if err != nil {
		return "", err
	}
	parsed, _ := url.Parse(repository)
	owner := strings.Split(strings.Trim(parsed.Path, "/"), "/")[0]
	return filepath.Join(filepath.Dir(credentialsFile), "project-credentials", owner, repoName), nil
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
		return errors.New("Enter a valid commit author name (up to 100 characters).")
	}
	if email == "" || len(email) > 254 || strings.ContainsAny(email, "\r\n\x00") {
		return errors.New("Enter a valid commit author email.")
	}
	parsed, err := mail.ParseAddress(email)
	if err != nil || parsed.Address != email {
		return errors.New("Enter a valid email address without a display name.")
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
