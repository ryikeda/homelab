# apps

One file per workload, each an Argo CD `Application` pointing at that workload's own manifests/Helm values elsewhere in this repo. `../root.yaml` watches this directory and applies whatever's declared here - adding a workload is a commit here, not a manual `kubectl`/`argocd` command.

`homepage.yaml` is the first one - see `../homepage/`.
