# HomeLab installation scripts

Run the root-level orchestrator. It lets you select one or more installers,
collects every required value before making changes, and executes the selected
installers by their numeric `PRIORITY` metadata. Terminal customization has a
late priority so it runs last when selected.

```bash
chmod +x orchestrator.sh scripts/*.sh
sudo ./orchestrator.sh
```

Individual installers remain directly executable from the `scripts/` folder.
