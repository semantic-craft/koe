use koe_runtime::credentials::{CredentialError, CredentialStore};
use std::ffi::{c_char, c_void, CStr, CString};

/// Synchronous platform credential callback. Operations are read=0, create=1,
/// delete=2, read legacy=3, authorize=4, prepare=5. Prepare returns a fresh
/// reference without storage I/O; create writes the item at that reference and
/// echoes it. Return 0 on success, 1 when missing, or -1 on failure. Successful
/// reads/prepares/creates write a terminated UTF-8 result.
/// The callback must not reenter the host API or retain borrowed pointers.
pub type KoeCredentialCallback =
    unsafe extern "C" fn(*mut c_void, u32, *const c_char, *const c_char, *mut c_char, usize) -> i32;

pub(crate) struct PlatformCredentials {
    pub callback: KoeCredentialCallback,
    pub context: usize,
    pub isolated: bool,
}
impl PlatformCredentials {
    fn call(
        &mut self,
        operation: u32,
        reference: &str,
        value: &str,
    ) -> Result<Option<String>, CredentialError> {
        let reference = CString::new(reference).map_err(|_| CredentialError)?;
        let value = CString::new(value).map_err(|_| CredentialError)?;
        let mut output = vec![0u8; 65_537];
        // SAFETY: Session creation requires the callback/context to outlive the session.
        // Buffers are valid for this synchronous call and output capacity is explicit.
        let status = unsafe {
            (self.callback)(
                self.context as *mut c_void,
                operation,
                reference.as_ptr(),
                value.as_ptr(),
                output.as_mut_ptr().cast(),
                output.len(),
            )
        };
        match status {
            1 => Ok(None),
            0 => CStr::from_bytes_until_nul(&output)
                .map_err(|_| CredentialError)?
                .to_str()
                .map(|s| Some(s.to_owned()))
                .map_err(|_| CredentialError),
            _ => Err(CredentialError),
        }
    }
}
impl CredentialStore for PlatformCredentials {
    fn isolated(&self) -> bool {
        self.isolated
    }
    fn read(&mut self, reference: &str) -> Result<Option<String>, CredentialError> {
        self.call(0, reference, "")
    }
    fn prepare(&mut self, secret: &str) -> Result<String, CredentialError> {
        self.call(5, "", secret)?.ok_or(CredentialError)
    }
    fn create(&mut self, reference: &str, secret: &str) -> Result<(), CredentialError> {
        match self.call(1, reference, secret)? {
            Some(created) if created == reference => Ok(()),
            _ => Err(CredentialError),
        }
    }
    fn delete(&mut self, reference: &str) -> Result<(), CredentialError> {
        self.call(2, reference, "").map(|_| ())
    }
    fn read_legacy(&mut self) -> Result<Option<String>, CredentialError> {
        self.call(3, "", "")
    }
    fn authorize(&mut self, reference: Option<&str>) -> Result<(), CredentialError> {
        self.call(4, reference.unwrap_or(""), "").map(|_| ())
    }
}
