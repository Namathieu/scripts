# HomeLab installation scripts

Run the root-level orchestrator. It lets you select one or more installers,
collects every required value before making changes, and executes the selected
installers by their numeric `PRIORITY` metadata. Terminal customization has a
late priority so it runs last when selected.

Download the repository and run the orchestrator:

```bash
wget -qO- https://github.com/Namathieu/scripts/archive/refs/heads/main.tar.gz | tar -xz && cd scripts-main && chmod +x orchestrator.sh scripts/*.sh && sudo ./orchestrator.sh
```

If the repository is already downloaded:

```bash
chmod +x orchestrator.sh scripts/*.sh
sudo ./orchestrator.sh
```

Individual installers remain directly executable from the `scripts/` folder.
