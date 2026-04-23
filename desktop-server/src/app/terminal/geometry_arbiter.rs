#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TerminalClientKind {
    Unknown,
    SystemTerminal,
    DesktopApp,
    MobileApp,
}

impl TerminalClientKind {
    pub fn from_wire(value: Option<&str>) -> Self {
        match value.unwrap_or_default() {
            "system_terminal" => Self::SystemTerminal,
            "desktop_app" => Self::DesktopApp,
            "mobile_app" => Self::MobileApp,
            _ => Self::Unknown,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum GeometryAuthoritySource {
    ServerDefault,
    DesktopApp,
    SystemTerminal,
}

impl GeometryAuthoritySource {
    pub fn as_api_str(self) -> &'static str {
        match self {
            Self::ServerDefault => "server_default",
            Self::DesktopApp => "desktop_app",
            Self::SystemTerminal => "system_terminal",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct TerminalSize {
    pub cols: u16,
    pub rows: u16,
}

impl TerminalSize {
    pub const fn new(cols: u16, rows: u16) -> Self {
        Self { cols, rows }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct GeometryUpdate {
    pub previous_size: TerminalSize,
    pub size: TerminalSize,
    pub previous_source: GeometryAuthoritySource,
    pub authority_source: GeometryAuthoritySource,
    pub geometry_generation: u64,
}

impl GeometryUpdate {
    pub fn pty_size_changed(self) -> bool {
        self.previous_size != self.size
    }

    pub fn authority_changed(self) -> bool {
        self.previous_source != self.authority_source
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct ViewerLeaseState {
    attached: bool,
    latest_size: Option<TerminalSize>,
    presence_epoch: u64,
}

impl ViewerLeaseState {
    fn register(&mut self) -> u64 {
        self.attached = true;
        self.presence_epoch = self.presence_epoch.saturating_add(1);
        self.presence_epoch
    }

    fn update_size(&mut self, size: TerminalSize) {
        self.attached = true;
        self.latest_size = Some(size);
    }

    fn unregister(&mut self) {
        self.attached = false;
        self.latest_size = None;
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct TerminalGeometryArbiter {
    default_size: TerminalSize,
    effective_size: TerminalSize,
    authority_source: GeometryAuthoritySource,
    geometry_generation: u64,
    host_size: Option<TerminalSize>,
    desktop_viewer: ViewerLeaseState,
    system_viewer: ViewerLeaseState,
}

impl TerminalGeometryArbiter {
    pub fn new(default_cols: u16, default_rows: u16) -> Self {
        let default_size = TerminalSize::new(default_cols, default_rows);
        Self {
            default_size,
            effective_size: default_size,
            authority_source: GeometryAuthoritySource::ServerDefault,
            geometry_generation: 0,
            host_size: None,
            desktop_viewer: ViewerLeaseState {
                attached: false,
                latest_size: None,
                presence_epoch: 0,
            },
            system_viewer: ViewerLeaseState {
                attached: false,
                latest_size: None,
                presence_epoch: 0,
            },
        }
    }

    pub fn new_host_authority(cols: u16, rows: u16) -> Self {
        let size = TerminalSize::new(cols, rows);
        Self {
            default_size: size,
            effective_size: size,
            authority_source: GeometryAuthoritySource::SystemTerminal,
            geometry_generation: 0,
            host_size: Some(size),
            desktop_viewer: ViewerLeaseState {
                attached: false,
                latest_size: None,
                presence_epoch: 0,
            },
            system_viewer: ViewerLeaseState {
                attached: false,
                latest_size: None,
                presence_epoch: 0,
            },
        }
    }

    pub fn cols(self) -> u16 {
        self.effective_size.cols
    }

    pub fn rows(self) -> u16 {
        self.effective_size.rows
    }

    pub fn size(self) -> TerminalSize {
        self.effective_size
    }

    pub fn authority_source(self) -> GeometryAuthoritySource {
        self.authority_source
    }

    pub fn geometry_generation(self) -> u64 {
        self.geometry_generation
    }

    pub fn viewer_presence_epoch(self, kind: TerminalClientKind) -> u64 {
        match kind {
            TerminalClientKind::SystemTerminal => self.system_viewer.presence_epoch,
            TerminalClientKind::DesktopApp => self.desktop_viewer.presence_epoch,
            TerminalClientKind::MobileApp | TerminalClientKind::Unknown => 0,
        }
    }

    pub fn viewer_attached(self, kind: TerminalClientKind) -> bool {
        match kind {
            TerminalClientKind::SystemTerminal => self.system_viewer.attached,
            TerminalClientKind::DesktopApp => self.desktop_viewer.attached,
            TerminalClientKind::MobileApp | TerminalClientKind::Unknown => false,
        }
    }

    pub fn register_viewer(&mut self, kind: TerminalClientKind) -> u64 {
        match kind {
            TerminalClientKind::SystemTerminal => self.system_viewer.register(),
            TerminalClientKind::DesktopApp => self.desktop_viewer.register(),
            TerminalClientKind::MobileApp | TerminalClientKind::Unknown => 0,
        }
    }

    pub fn update_viewer_size(
        &mut self,
        kind: TerminalClientKind,
        cols: u16,
        rows: u16,
        expected_epoch: Option<u64>,
    ) -> Result<Option<GeometryUpdate>, u64> {
        let size = TerminalSize::new(cols, rows);
        let viewer = match kind {
            TerminalClientKind::SystemTerminal => &mut self.system_viewer,
            TerminalClientKind::DesktopApp => &mut self.desktop_viewer,
            TerminalClientKind::MobileApp | TerminalClientKind::Unknown => {
                return Ok(None);
            }
        };
        if let Some(expected_epoch) = expected_epoch {
            if expected_epoch != viewer.presence_epoch {
                return Err(viewer.presence_epoch);
            }
        }
        viewer.update_size(size);
        Ok(self.recompute())
    }

    pub fn unregister_viewer(
        &mut self,
        kind: TerminalClientKind,
        expected_epoch: Option<u64>,
    ) -> Result<Option<GeometryUpdate>, u64> {
        let viewer = match kind {
            TerminalClientKind::SystemTerminal => &mut self.system_viewer,
            TerminalClientKind::DesktopApp => &mut self.desktop_viewer,
            TerminalClientKind::MobileApp | TerminalClientKind::Unknown => {
                return Ok(None);
            }
        };
        if let Some(expected_epoch) = expected_epoch {
            if expected_epoch != viewer.presence_epoch {
                return Err(viewer.presence_epoch);
            }
        }
        viewer.unregister();
        Ok(self.recompute())
    }

    pub fn update_host_size(&mut self, cols: u16, rows: u16) -> Option<GeometryUpdate> {
        self.host_size = Some(TerminalSize::new(cols, rows));
        self.recompute()
    }

    fn recompute(&mut self) -> Option<GeometryUpdate> {
        let previous_size = self.effective_size;
        let previous_source = self.authority_source;

        let (next_source, next_size) = if let Some(host_size) = self.host_size {
            (GeometryAuthoritySource::SystemTerminal, host_size)
        } else if self.system_viewer.attached {
            (
                GeometryAuthoritySource::SystemTerminal,
                self.system_viewer.latest_size.unwrap_or(self.default_size),
            )
        } else if self.desktop_viewer.attached {
            (
                GeometryAuthoritySource::DesktopApp,
                self.desktop_viewer.latest_size.unwrap_or(self.default_size),
            )
        } else {
            (GeometryAuthoritySource::ServerDefault, self.default_size)
        };

        if previous_size == next_size && previous_source == next_source {
            return None;
        }

        self.effective_size = next_size;
        self.authority_source = next_source;
        self.geometry_generation = self.geometry_generation.saturating_add(1);
        Some(GeometryUpdate {
            previous_size,
            size: next_size,
            previous_source,
            authority_source: next_source,
            geometry_generation: self.geometry_generation,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::{
        GeometryAuthoritySource, TerminalClientKind, TerminalGeometryArbiter, TerminalSize,
    };

    #[test]
    fn hosted_terminal_size_is_system_terminal_authority() {
        let arbiter = TerminalGeometryArbiter::new_host_authority(120, 32);
        assert_eq!(
            arbiter.authority_source(),
            GeometryAuthoritySource::SystemTerminal
        );
        assert_eq!(arbiter.size(), TerminalSize::new(120, 32));
        assert_eq!(arbiter.geometry_generation(), 0);
    }

    #[test]
    fn system_terminal_beats_desktop_viewer_size() {
        let mut arbiter = TerminalGeometryArbiter::new(100, 30);
        let desktop_epoch = arbiter.register_viewer(TerminalClientKind::DesktopApp);
        let desktop_update = arbiter
            .update_viewer_size(TerminalClientKind::DesktopApp, 140, 40, Some(desktop_epoch))
            .expect("desktop epoch should match")
            .expect("desktop resize should change geometry");
        assert_eq!(
            desktop_update.authority_source,
            GeometryAuthoritySource::DesktopApp
        );

        let system_epoch = arbiter.register_viewer(TerminalClientKind::SystemTerminal);
        let system_update = arbiter
            .update_viewer_size(
                TerminalClientKind::SystemTerminal,
                180,
                50,
                Some(system_epoch),
            )
            .expect("system epoch should match")
            .expect("system resize should change geometry");
        assert_eq!(
            system_update.authority_source,
            GeometryAuthoritySource::SystemTerminal
        );
        assert_eq!(arbiter.size(), TerminalSize::new(180, 50));
    }

    #[test]
    fn desktop_viewer_takes_over_after_system_terminal_detaches() {
        let mut arbiter = TerminalGeometryArbiter::new(100, 30);
        let desktop_epoch = arbiter.register_viewer(TerminalClientKind::DesktopApp);
        arbiter
            .update_viewer_size(TerminalClientKind::DesktopApp, 140, 40, Some(desktop_epoch))
            .expect("desktop epoch should match");
        let system_epoch = arbiter.register_viewer(TerminalClientKind::SystemTerminal);
        arbiter
            .update_viewer_size(
                TerminalClientKind::SystemTerminal,
                180,
                50,
                Some(system_epoch),
            )
            .expect("system epoch should match");

        let update = arbiter
            .unregister_viewer(TerminalClientKind::SystemTerminal, Some(system_epoch))
            .expect("system detach should use current epoch")
            .expect("desktop viewer should take over");
        assert_eq!(update.authority_source, GeometryAuthoritySource::DesktopApp);
        assert_eq!(arbiter.size(), TerminalSize::new(140, 40));
    }

    #[test]
    fn stale_epoch_is_rejected_without_mutating_state() {
        let mut arbiter = TerminalGeometryArbiter::new(120, 32);
        let desktop_epoch = arbiter.register_viewer(TerminalClientKind::DesktopApp);
        let stale = arbiter.update_viewer_size(
            TerminalClientKind::DesktopApp,
            150,
            45,
            Some(desktop_epoch.saturating_sub(1)),
        );
        assert_eq!(stale, Err(desktop_epoch));
        assert_eq!(arbiter.size(), TerminalSize::new(120, 32));
        assert_eq!(
            arbiter.authority_source(),
            GeometryAuthoritySource::ServerDefault
        );
    }
}
