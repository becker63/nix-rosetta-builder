{
  description = "Lima-based, Rosetta 2-enabled, Apple silicon (macOS/Darwin)-hosted Linux builder";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    nixos-generators = {
      url = "github:nix-community/nixos-generators";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixos-generators, nixpkgs }:
  let
    darwinSystem = "aarch64-darwin";
    linuxSystem = builtins.replaceStrings [ "darwin" ] [ "linux" ] darwinSystem;
    lib = nixpkgs.lib;

    name = "rosetta-builder"; # update `darwinGroup` if adding or removing special characters
    linuxHostName = name; # no prefix because it's user visible (on prompt when `ssh`d in)
    linuxUser = "builder"; # follow linux-builder/darwin-builder precedent

    sshKeyType = "ed25519";
    sshHostPrivateKeyFileName = "ssh_host_${sshKeyType}_key";
    sshHostPublicKeyFileName = "${sshHostPrivateKeyFileName}.pub";
    sshUserPrivateKeyFileName = "ssh_user_${sshKeyType}_key";
    sshUserPublicKeyFileName = "${sshUserPrivateKeyFileName}.pub";

    debug = false; # enable root access in VM and debug logging

  in {
    packages."${linuxSystem}".default = nixos-generators.nixosGenerate (
    let
      imageFormat = "qcow-efi"; # must match `vmYaml.images.location`s extension
      pkgs = nixpkgs.legacyPackages."${linuxSystem}";

      sshdKeys = "sshd-keys";
      sshDirPath = "/etc/ssh";
      sshHostPrivateKeyFilePath = "${sshDirPath}/${sshHostPrivateKeyFileName}";

    in {
      format = imageFormat;

      modules = [ {
        boot = {
          kernelParams = [ "console=tty0" ];

          loader = {
            efi.canTouchEfiVariables = true;
            systemd-boot.enable = true; 
          };
        };

        documentation.enable = false;

        fileSystems = {
          "/".options = [ "discard" "noatime" ];
          "/boot".options = [ "discard" "noatime" "umask=0077" ];
        };

        networking.hostName = linuxHostName;

        nix = {
          channel.enable = false;
          registry.nixpkgs.flake = nixpkgs;

          settings = {
            auto-optimise-store = true;
            experimental-features = [ "flakes" "nix-command" ];
            min-free = "5G";
            max-free = "7G";
            trusted-users = [ linuxUser ];
          };
        };

        security = {
          polkit = lib.optionalAttrs debug {
            enable = true;
            extraConfig = ''
              polkit.addRule(function(action, subject) {
                if (
                  (
                    action.id === "org.freedesktop.login1.power-off"
                    || action.id === "org.freedesktop.login1.reboot"
                  )
                  && subject.user === "${linuxUser}"
                ) {
                  return "yes";
                } else {
                  return "no";
                }
              })
            '';
          };

          sudo = {
            enable = debug;
            wheelNeedsPassword = !debug;
          };
        };

        services = {
          getty = lib.optionalAttrs debug { autologinUser = linuxUser; };

          openssh = {
            enable = true;
            hostKeys = []; # disable automatic host key generation

            settings = {
              HostKey = sshHostPrivateKeyFilePath;
              PasswordAuthentication = false;
            };
          };
        };

        system = {
          disableInstallerTools = true;
          stateVersion = "24.05";
        };

        systemd.services."${sshdKeys}" =
        let
          sshdKeysVirtiofsTag = "mount0"; # suffix must match `vmYaml.mounts.location`s order
          sshdKeysDirPath = "/var/${sshdKeys}";
          sshAuthorizedKeysUserFilePath = "${sshDirPath}/authorized_keys.d/${linuxUser}";
          sshdService = "sshd.service";

        in {
          before = [ sshdService ];
          description = "Install sshd's host and authorized keys";
          enableStrictShellChecks = true;
          path = [ pkgs.mount pkgs.umount ];
          requiredBy = [ sshdService ];

          # must be idempotent in the face of partial failues
          script =
          let
            sshAuthorizedKeysUserFilePathSh = lib.escapeShellArg sshAuthorizedKeysUserFilePath;
            sshHostPrivateKeyFileNameSh = lib.escapeShellArg sshHostPrivateKeyFileName;
            sshHostPrivateKeyFilePathSh = lib.escapeShellArg sshHostPrivateKeyFilePath;
            sshUserPublicKeyFileNameSh = lib.escapeShellArg sshUserPublicKeyFileName;
            sshdKeysDirPathSh = lib.escapeShellArg sshdKeysDirPath;
            sshdKeysVirtiofsTagSh = lib.escapeShellArg sshdKeysVirtiofsTag;

          in ''
            mkdir -p ${sshdKeysDirPathSh}
            mount \
              -t 'virtiofs' \
              -o 'nodev,noexec,nosuid,ro' \
              ${sshdKeysVirtiofsTagSh} \
              ${sshdKeysDirPathSh}

            mkdir -p "$(dirname ${sshHostPrivateKeyFilePathSh})"
            (
              umask 'go='
              cp ${sshdKeysDirPathSh}/${sshHostPrivateKeyFileNameSh} ${sshHostPrivateKeyFilePathSh}
            )

            mkdir -p "$(dirname ${sshAuthorizedKeysUserFilePathSh})"
            cp ${sshdKeysDirPathSh}/${sshUserPublicKeyFileNameSh} ${sshAuthorizedKeysUserFilePathSh}
            chmod 'a+r' ${sshAuthorizedKeysUserFilePathSh}

            umount ${sshdKeysDirPathSh}
            rmdir ${sshdKeysDirPathSh}
          '';

          serviceConfig.Type = "oneshot";
          unitConfig.ConditionPathExists = "!${sshAuthorizedKeysUserFilePath}";
        };

        users = {
          allowNoPasswordLogin = true;
          mutableUsers = false;

          users."${linuxUser}" = {
            isNormalUser = true;
            extraGroups = lib.optionals debug [ "wheel" ];
          };
        };

        virtualisation.rosetta = {
          enable = true;
          mountTag = "vz-rosetta";
        };
      } ];

      system = linuxSystem;
    });

    devShells."${darwinSystem}".default =
    let
      pkgs = nixpkgs.legacyPackages."${darwinSystem}";
    in pkgs.mkShell {
      packages = [ pkgs.lima ];
    };

    darwinModules.default = { lib, pkgs, ... }:
    let
      cores = 8;
      daemonName = "${name}d";
      darwinGid = 349;
      darwinGroup = builtins.replaceStrings [ "-" ] [ "" ] name; # keep in sync with `name`s format
      darwinUid = darwinGid;
      darwinUser = "_${darwinGroup}";
      linuxSshdKeysDirName = "linux-sshd-keys";
      port = 31122;
      sshGlobalKnownHostsFileName = "ssh_known_hosts";
      sshHost = name; # no prefix because it's user visible (in `sudo ssh '${sshHost}'`)
      sshHostKeyAlias = "${sshHost}-key";
      workingDirPath = "/var/lib/${name}";

      vmYaml = (pkgs.formats.yaml {}).generate "${name}.yaml" {
        containerd.user = false;
        cpus = cores;

        images = [{
          # extension must match `imageFormat`
          location = "${self.packages."${linuxSystem}".default}/nixos.qcow2";
        }];

        memory = "6GiB";

        mounts = [{
          # order must match `sshdKeysVirtiofsTag`s suffix
          location = "${workingDirPath}/${linuxSshdKeysDirName}";
        }];

        rosetta.enabled = true;
        ssh.localPort = port;
      };

    in {
      environment.etc."ssh/ssh_config.d/100-${sshHost}.conf".text = ''
        Host "${sshHost}"
          GlobalKnownHostsFile "${workingDirPath}/${sshGlobalKnownHostsFileName}"
          Hostname localhost
          HostKeyAlias "${sshHostKeyAlias}"
          Port "${toString port}"
          StrictHostKeyChecking yes
          User "${linuxUser}"
          IdentityFile "${workingDirPath}/${sshUserPrivateKeyFileName}"
      '';

      users = {
        knownUsers = [ darwinUser ];

        users."${darwinUser}" = {
          gid = darwinGid;
          home = workingDirPath;
          isHidden = true;
          uid = darwinUid;
        };
      };

      launchd.daemons."${daemonName}" = {
        path = [ pkgs.coreutils pkgs.gnugrep pkgs.lima pkgs.openssh "/usr/bin/" ];

        script =
        let
          darwinUserSh = lib.escapeShellArg darwinUser;
          linuxHostNameSh = lib.escapeShellArg linuxHostName;
          linuxSshdKeysDirNameSh = lib.escapeShellArg linuxSshdKeysDirName;
          sshGlobalKnownHostsFileNameSh = lib.escapeShellArg sshGlobalKnownHostsFileName;
          sshHostKeyAliasSh = lib.escapeShellArg sshHostKeyAlias;
          sshHostPrivateKeyFileNameSh = lib.escapeShellArg sshHostPrivateKeyFileName;
          sshHostPublicKeyFileNameSh = lib.escapeShellArg sshHostPublicKeyFileName;
          sshKeyTypeSh = lib.escapeShellArg sshKeyType;
          sshUserPrivateKeyFileNameSh = lib.escapeShellArg sshUserPrivateKeyFileName;
          sshUserPublicKeyFileNameSh = lib.escapeShellArg sshUserPublicKeyFileName;
          vmNameSh = lib.escapeShellArg "${name}-vm";
          vmYamlSh = lib.escapeShellArg vmYaml;

        in ''
          set -e
          set -u

          umask 'g-w,o='
          chmod 'g-w,o=' .

          # must be idempotent in the face of partial failues
          limactl list -q 2>'/dev/null' | grep -q ${vmNameSh} || {
            yes | ssh-keygen \
              -C ${darwinUserSh}@darwin -f ${sshUserPrivateKeyFileNameSh} -N "" -t ${sshKeyTypeSh}
            yes | ssh-keygen \
              -C root@${linuxHostNameSh} -f ${sshHostPrivateKeyFileNameSh} -N "" -t ${sshKeyTypeSh}

            mkdir -p ${linuxSshdKeysDirNameSh}
            mv \
              ${sshUserPublicKeyFileNameSh} ${sshHostPrivateKeyFileNameSh} ${linuxSshdKeysDirNameSh}

            echo ${sshHostKeyAliasSh} "$(cat ${sshHostPublicKeyFileNameSh})" \
            >${sshGlobalKnownHostsFileNameSh}

            limactl create --name=${vmNameSh} ${vmYamlSh}
          }

          exec limactl start ${lib.optionalString debug "--debug"} --foreground ${vmNameSh}
        '';

        serviceConfig = {
          KeepAlive = true;
          RunAtLoad = true;
          UserName = darwinUser;
          WorkingDirectory = workingDirPath;
        } // lib.optionalAttrs debug {
          StandardErrorPath = "/tmp/${daemonName}.err.log";
          StandardOutPath = "/tmp/${daemonName}.out.log";
        };
      };

      nix = {
        buildMachines = [{
          hostName = sshHost;
          maxJobs = cores;
          protocol = "ssh-ng";
          supportedFeatures = [ "benchmark" "big-parallel" "kvm" ];
          systems = [ linuxSystem "x86_64-linux" ];
        }];

        distributedBuilds = true;
        settings.builders-use-substitutes = true;
      };

      system.activationScripts.extraActivation.text =
      let
        gidSh = lib.escapeShellArg (toString darwinGid);
        groupSh = lib.escapeShellArg darwinGroup;
        groupPathSh = lib.escapeShellArg "/Groups/${darwinGroup}";

        uidSh = lib.escapeShellArg (toString darwinUid);
        userSh = lib.escapeShellArg darwinUser;
        userPathSh = lib.escapeShellArg "/Users/${darwinUser}";

        workingDirPathSh = lib.escapeShellArg workingDirPath;

      in lib.mkAfter ''
        printf >&2 'setting up group %s...\n' ${groupSh}

        if ! primaryGroupId="$(dscl . -read ${groupPathSh} 'PrimaryGroupID' 2>'/dev/null')" ; then
          printf >&2 'creating group %s...\n' ${groupSh}
          dscl . -create ${groupPathSh} 'PrimaryGroupID' ${gidSh}
        elif [[ "$primaryGroupId" != *\ ${gidSh} ]] ; then
          printf >&2 \
            '\e[1;31merror: existing group: %s has unexpected %s\e[0m\n' \
            ${groupSh} \
            "$primaryGroupId"
          exit 1
        fi
        unset 'primaryGroupId'


        printf >&2 'setting up user %s...\n' ${userSh}

        if ! uid="$(id -u ${userSh} 2>'/dev/null')" ; then
          printf >&2 'creating user %s...\n' ${userSh}
          dscl . -create ${userPathSh}
          dscl . -create ${userPathSh} 'PrimaryGroupID' ${gidSh}
          dscl . -create ${userPathSh} 'NFSHomeDirectory' ${workingDirPathSh}
          dscl . -create ${userPathSh} 'UserShell' '/usr/bin/false'
          dscl . -create ${userPathSh} 'IsHidden' 1
          dscl . -create ${userPathSh} 'UniqueID' ${uidSh} # must be last so `id` only now succeeds
        elif [ "$uid" -ne ${uidSh} ] ; then
          printf >&2 \
            '\e[1;31merror: existing user: %s has unexpected UID: %s\e[0m\n' \
            ${userSh} \
            "$uid"
          exit 1
        fi
        unset 'uid'


        printf >&2 'setting up working directory %s...\n' ${workingDirPathSh}
        mkdir -p ${workingDirPathSh}
        chown ${userSh}:${groupSh} ${workingDirPathSh}
      '';

    };
  };
}
