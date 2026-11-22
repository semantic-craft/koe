use koe_runtime::credentials::{CredentialError, CredentialStore};
use std::ffi::{CStr, CString, c_char, c_void};
use std::sync::atomic::{Ordering, compiler_fence};

/// Synchronous platform credential callback. Operations are read=0, create=1,
/// delete=2, read legacy=3, authorize=4, prepare=5. Prepare returns a fresh
/// reference without storage I/O; create writes the item at that reference and
/// echoes it. Return 0 on success, 1 when missing, or -1 on failure. Successful
/// reads/prepares/creates write a terminated UTF-8 result.
/// The callback must not reenter the host API or retain borrowed pointers.
pub type KoeCredentialCallback =
    unsafe extern "C" fn(*mut c_void, u32, *const c_char, *const c_char, *mut c_char, usize) -> i32;

struct ZeroizingBuf(Vec<u8>);

impl ZeroizingBuf {
    fn c_string(input: &str) -> Result<Self, CredentialError> {
        if input.as_bytes().contains(&0) {
            return Err(CredentialError);
        }
        let mut bytes = Vec::with_capacity(input.len() + 1);
        bytes.extend_from_slice(input.as_bytes());
        bytes.push(0);
        Ok(Self(bytes))
    }

    fn zeroed(len: usize) -> Self {
        Self(vec![0u8; len])
    }

    fn as_c_ptr(&self) -> *const c_char {
        self.0.as_ptr().cast()
    }

    fn as_mut_c_ptr(&mut self) -> *mut c_char {
        self.0.as_mut_ptr().cast()
    }

    fn as_slice(&self) -> &[u8] {
        &self.0
    }

    fn len(&self) -> usize {
        self.0.len()
    }
}

impl Drop for ZeroizingBuf {
    fn drop(&mut self) {
        for byte in &mut self.0 {
            // SAFETY: `byte` is a valid, aligned, uniquely borrowed mutable reference inside `self.0`.
            unsafe { std::ptr::write_volatile(byte, 0) };
        }
        compiler_fence(Ordering::SeqCst);
    }
}

pub(crate) struct PlatformCredentials {
    pub callback: KoeCredentialCallback,
    pub context: *mut c_void,
    pub isolated: bool,
}

// SAFETY: `koe_host_session_create_with_credentials` requires the caller to guarantee
// that `context` remains valid until session destruction and supports serialized calls on any thread.
unsafe impl Send for PlatformCredentials {}

impl PlatformCredentials {
    fn call(
        &mut self,
        operation: u32,
        reference: &str,
        value: &str,
    ) -> Result<Option<String>, CredentialError> {
        let reference = CString::new(reference).map_err(|_| CredentialError)?;
        let value = ZeroizingBuf::c_string(value)?;
        let mut output = ZeroizingBuf::zeroed(65_537);
        // SAFETY: Session creation requires the callback/context to outlive the session.
        // Buffers are valid for this synchronous call and output capacity is explicit.
        let status = unsafe {
            (self.callback)(
                self.context,
                operation,
                reference.as_ptr(),
                value.as_c_ptr(),
                output.as_mut_c_ptr(),
                output.len(),
            )
        };
        match status {
            1 => Ok(None),
            0 => CStr::from_bytes_until_nul(output.as_slice())
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
    fn prepare_for_slot(&mut self, slot: &str, secret: &str) -> Result<String, CredentialError> {
        self.call(5, slot, secret)?.ok_or(CredentialError)
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
