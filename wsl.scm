;; Guix System for WSL2.
;;
;; image.scm builds the release tarball from this file and installs a copy
;; of it as /etc/config.scm on first boot.  Edit that copy, then:
;;
;;   sudo guix system reconfigure /etc/config.scm
;;
;; It is upstream's (gnu system images wsl2) operating system with fixes
;; for problems that otherwise appear after the first restart or the first
;; reconfigure.  Needs Guix from 2026-09-17 or later (make-wsl-os).

(use-modules (gnu)
             (gnu system images wsl2)
             ((gnu packages base) #:select (libc-utf8-locales-for-target))
             ((guix utils) #:select (%current-system))
             ((guix build syscalls) #:prefix syscalls:)
             (srfi srfi-1))

(define %user "guest")
(define %uid 1000)
(define %host "gnu")

;; Upstream's wsl.conf sets [user] default=%user.  That skips root's
;; login shell -- the boot program -- so after any `wsl --terminate' or
;; host reboot nothing boots /run/current-system or shepherd.  Keep root
;; as the WSL default user; the boot program drops to %user via sudo.
;; drvfs mounts default to the WSL default user's IDs, so give /mnt/c
;; to %user explicitly or it can neither write there nor run .exe files.
(define %wsl-conf
  (plain-file "wsl.conf" (string-append "\
[user]
default=root

[boot]
systemd=false

[automount]
enabled=true
root=/mnt
options=uid=" (number->string %uid) "

[network]
hostname=" %host "
generateHosts=true
generateResolvConf=true

[interop]
enabled=true
appendWindowsPath=true
")))

;; Upstream's boot program forks shepherd inside the wsl.exe session
;; that triggered boot, so shepherd stops when that session ends.  Run
;; the upstream program once in a fresh session with stdio on a log
;; file, wait for it to bring shepherd up, then exec it again for the
;; actual login (it skips booting once /run/current-system exists).
;; WSL resolves `--cd ~' (Windows Terminal's default) against root, the
;; WSL default user, so map /root to USER's home.
(define (detached-wsl-boot-program user)
  (let ((boot (wsl-boot-program user)))
    (program-file
     "wsl-boot-program-detached"
     #~(begin
         (unless (file-exists? "/run/current-system")
           (let ((pid (primitive-fork)))
             (when (zero? pid)
               (setsid)
               (let ((null (open-fdes "/dev/null" O_RDONLY))
                     (log (open-fdes "/var/log/wsl-boot.log"
                                     (logior O_WRONLY O_CREAT O_APPEND)
                                     #o640)))
                 (dup2 null 0)
                 (dup2 log 1)
                 (dup2 log 2))
               (execl #$boot "wsl-boot-program" "-c" "true"))
             (waitpid pid)))
         (when (string=? (getcwd) "/root")
           (chdir (passwd:dir (getpw #$user))))
         (apply execl #$boot "wsl-boot-program" (cdr (command-line)))))))

;; WSL mounts / itself.  `guix system reconfigure' still wants a root
;; file system holding the store, and checks that its device exists:
;; name whatever WSL mounted on / right now (/dev/sdX; the letter
;; depends on attach order).  Nothing mounts it.  `guix system image'
;; replaces it with a root of its own.
(define %root-device
  (or (any (lambda (mount)
             (and (string=? (syscalls:mount-point mount) "/")
                  (syscalls:mount-source mount)))
           (syscalls:mounts))
      "none"))

;; Guix's essential cleanup service empties /tmp, /var/run and /run at
;; boot.  WSL mounts a fresh /run at every start, already holding the
;; booting session's interop socket (/run/WSL/PID_interop): deleting it
;; leaves the first terminal after a restart unable to run .exe files.
;; Same cleanup, minus /run.
(define (wsl-cleanup-gexp _)
  (with-imported-modules '((guix build utils))
    #~(begin
        (use-modules (guix build utils))
        (for-each (lambda (thunk)
                    (catch 'system-error thunk (const #f)))
                  (list (lambda () (delete-file "/etc/group.lock"))
                        (lambda () (delete-file "/etc/passwd.lock"))
                        (lambda () (delete-file "/etc/.pwd.lock"))
                        (lambda ()
                          (setenv "GUIX_LOCPATH"
                                  #+(file-append
                                     (libc-utf8-locales-for-target
                                      (%current-system))
                                     "/lib/locale"))
                          (setlocale LC_CTYPE "en_US.utf8"))
                        (lambda () (delete-file-recursively "/tmp"))
                        (lambda () (delete-file-recursively "/var/run"))
                        (lambda () (mkdir "/tmp" #o1777) (chmod "/tmp" #o1777))
                        (lambda ()
                          (mkdir "/var/run" #o755)
                          (chmod "/var/run" #o755)))))))

(define wsl-cleanup-service-type
  (service-type
    (name 'wsl-cleanup)
    (extensions
     (list (service-extension boot-service-type wsl-cleanup-gexp)))
    (description "Like cleanup-service-type, but leave WSL's /run alone.")))

;; The boot program logs in through sudo, which keeps DISPLAY but drops
;; the rest of what WSL sets up for the session: WSLg audio, interop.
(define %sudoers
  (plain-file "sudoers" "\
Defaults env_keep += \"PULSE_SERVER WAYLAND_DISPLAY WSL_DISTRO_NAME WSL_INTEROP WSLENV\"
root ALL=(ALL) ALL
%wheel ALL=(ALL) ALL
"))

(define %base-os
  (make-wsl-os #:user %user #:uid %uid #:hostname %host))

(operating-system
  (inherit %base-os)
  (sudoers-file %sudoers)
  (essential-services
   (map (lambda (s)
          (if (eq? (service-kind s) cleanup-service-type)
              (service wsl-cleanup-service-type #f)
              s))
        (operating-system-default-essential-services
         this-operating-system)))
  (file-systems (list (file-system
                        (mount-point "/")
                        (device %root-device)
                        (type "ext4")
                        (check? #f))))
  (users (map (lambda (account)
                (if (string=? (user-account-name account) "root")
                    (user-account
                      (inherit account)
                      (shell (detached-wsl-boot-program %user)))
                    account))
              (operating-system-users %base-os)))
  (services
   (cons (simple-service 'wsl-conf etc-service-type
                         `(("wsl.conf" ,%wsl-conf)))
         (remove (lambda (service)
                   (eq? (service-type-name (service-kind service))
                        'wsl-meta))
                 (operating-system-user-services %base-os)))))
