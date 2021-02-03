#!/usr/bin/env python3

import sys, os, re, contextlib, yaml, tempfile, git, logging, time, urllib.request, json, requests
from getopt import getopt
from getopt import GetoptError
from subprocess import Popen,PIPE
from distutils.version import LooseVersion
from datetime import datetime

logger = logging.getLogger()

class DeviceRepo:
    def __init__(self, remote, recurse, version, path, token):
        self.remote = remote
        self.path = path
        if self.path == None:
            self.path = os.getcwd()
        self.recurse = True
        self.version = version
        self.token = token

    def clone(self):
        if not os.path.exists(self.path):
            os.mkdir(self.path)
        logger.info ("Cloning " + self.remote + " into " + self.path)
        r = git.Repo.clone_from(self.remote, self.path)
        with pushd(self.path):
            self.checkout_branch_head(self.version, self.path)
            if self.token != None:
                # Patch meta-balena to use Github token authentication
                self.subm_token_auth(os.getcwd(), "url = https://github.com/balena-os/meta-balena.git", self.token)
                # Patch private submodules to use Github token authentication
                self.subm_token_auth(os.getcwd(), "url = https://github.com/balena-os/meta-dt-cloudconnector.git", self.token)
        if self.recurse:
            for submodule in r.submodules:
                submodule.update(init=True)

    def find_highest_tag(self, version):
        versions = []
        if version == None:
            version = self.version
        pat = "v" + version + "*"
        process = Popen(['git', 'ls-remote', '--tags', '--refs',  self.remote, pat], stdout=PIPE, stderr=PIPE)
        stdout, stderr = process.communicate()
        if stdout:
            prefix = "refs/tags/"
            data = stdout.decode("utf-8").split()
            for i, item in enumerate(data):
                if item.startswith(prefix):
                    versions.append(item[len(prefix):])
            return sorted(versions, key=LooseVersion, reverse=True)[0]
        else:
            logger.error("No such version %s in %s" % (version, self.remote))
            logger.debug(stderr)

    def checkout_branch_head(self, version, path):
        if version == None:
            version = self.version
        if path == None:
            path = self.path
        head = self.find_highest_tag(version)
        if head == None:
                   logger.error ("No such release %s in %s" % (version, self.remote))
                   sys.exit(-1)
        r = git.Repo(path)
        r.git.checkout('-b', head, "refs/tags/" + head)
        logger.info ("Checked out at refs/tags/" + head)
        return head

    def branch_or_checkout(self, name, path):
        if path == None:
            path = self.path
        r = git.Repo(path)
        try:
            logger.info ("Checking out " + name)
            r.git.checkout('-b', name, "origin/" + name)
        except:
            logger.info ("Branching " + name)
            r.create_head(name)
            r.heads[name].checkout()
        return True

    def branch_exists(self, branch):
        if branch == None:
            branch = self.version
        process = Popen(['git', 'ls-remote', '--heads', self.remote, branch], stdout=PIPE, stderr=PIPE)
        stdout, stderr = process.communicate()
        if stdout:
            return True
        else:
            logger.debug("No ls-remote match: " + str(stderr))
            return False

    def commit(self, message, path):
        if path == None:
            path = self.path
        r = git.Repo(path)
        reader = r.config_reader()
        name = reader.get_value("user", "name")
        email = reader.get_value("user", "email")
        r.git.add(".")
        logger.info ("Commiting " + message)
        try:
            r.git.commit('-m', message, '-m', 'Change-type: none')
        except git.exc.GitCommandError as e:
            if e.status == 1:
               logger.info ("Commit did not happen for %s - already updated" % (path))
            else:
                logger.error ("Commit did not happen")
                logger.debug(e)
                sys.exit(-1)

    def push(self, branch, path):
        if path == None:
            path = self.path
        r = git.Repo(path)
        logger.info ("Pushing " + branch + " to " + r.remotes[0].config_reader.get("url"))
        origin = r.remote(name='origin')
        try:
            r.git.push(origin, branch)
        except git.exc.GitCommandError as e:
            logger.debug(e)
            if e.status == 1:
                logger.warn("Did not push " + branch)
            elif e.status == 128:
                logger.error("Authentication error - aborting")
            sys.exit(-1)

    def tag(self, version, ref, path, message):
        if path == None:
            path = self.path
        if ref == None:
            ref = "HEAD"
        if version == None:
            logger.error ("Version is required")
            sys.exit(-1)
        r = git.Repo(path)
        logger.info ("Tagging %s with %s" % (ref, version))
        r.create_tag(version, ref, message=version + ": " + message + "\nChange-type: none")

    def ignore(self, filename):
        r = git.Repo(os.path.dirname(filename))
        logger.debug("Ignoring local changes to " + filename)
        r.git.update_index('--assume-unchanged', filename)

    def subm_token_auth(self, repoDir, target, token):
        filename = repoDir + os.sep + ".gitmodules"
        with open(filename, 'r') as original: lines = original.readlines()
        prefix = "url = https://"
        if prefix not in target:
            logger.debug ("Invalid target url" + target)
            return
        count = 0
        newpath = None
        for line in lines:
            if target in line:
                path = line[len(prefix)+1:]
                newpath = '\t' + prefix + token + '@' + path
                break
            count += 1
        if newpath != None:
            lines[count] = newpath
            with open(filename, 'w') as modified: modified.write("".join(lines))
        self.ignore(filename)

class Devices:
    def __init__(self, arg_dict):
        self.canonical_device_list = []
        self.device_list = {}
        self.arg_dict = arg_dict

    def resolve_aliases(self, device):
        if device == "intel-nuc":
            return "genericx86-64"
        elif device == "raspberry-pi":
            return "raspberrypi"
        elif device == "raspberry-pi2":
            return "raspberrypi2"
        elif device == "beaglebone-black":
            return "beaglebone"
        elif device == "intel-edison":
            return "edison"
        else:
            return device

    def build_devices(self):
        self.fetch_canonical_device_list(self.arg_dict['api-token'])
        deprecated_devices = []
        missing_devices = []
        for device in self.device_list:
            if device not in self.canonical_device_list:
                if self.arg_dict['api-token'] != None:
                    # Device is present in device repository but not in API device endpoint
                    deprecated_devices.append(device)
        for device in self.canonical_device_list:
            if device in self.device_list:
                if self.arg_dict['jenkins-user'] != None and self.arg_dict['jenkins-token'] != None:
                    self.build_and_deploy(device, self.device_list[device])
                continue
            else:
                missing_devices.append(device)

        if deprecated_devices:
            logger.warning ("The following deprecated devices might need to be removed from repository:\t" + ",".join(deprecated_devices))
        if not missing_devices:
            logger.info ("All canonical devices have an" + self.arg_dict["esrVersion"] + "  ESR branch now.")
        else:
            logger.warning ("The following devices are not present in the ESR repository list so no ESR releases have been created:\t" + ",".join(missing_devices))

    def build_and_deploy(self, device, esr_tag):
        jobname = "balenaOS-deploy-ESR"
        url = "https://jenkins.dev.resin.io/job/%s/buildWithParameters" % (jobname)
        params = { 'board':self.resolve_aliases(device), 'tag':esr_tag, 'deployTo':self.arg_dict['deploy-environment']}
        logger.info ("Deploying %s ESR version %s to %s" % (device, esr_tag, self.arg_dict['deploy-environment']))
        requests.post(url, auth=(self.arg_dict['jenkins-user'], self.arg_dict['jenkins-token']), data=params)

    def build_device_types_json(self):
        process = Popen("./balena-yocto-scripts/build/build-device-type-json.sh", stdout=PIPE, stderr=PIPE)
        stdout, stderr = process.communicate()

    def set_device_types(self, version):
        files = []
        self.build_device_types_json()
        files += [each for each in os.listdir(os.getcwd()) if each.endswith(".json")]
        for f in files:
            with open(f, "r") as fd:
                jobj = json.load(fd)
                self.device_list.update({jobj['slug']: version})

    def fetch_canonical_device_list(self, token=None):
        apiEnv = "balena-cloud.com/"
        translation = "v6"
        url = "https://api." + apiEnv + translation + "/device_type?$select=slug"
        header = {}
        if token != None:
            header = {'Authorization': "bearer " + token}
        raw = urllib.request.urlopen(urllib.request.Request(url, headers=header))
        json_obj = json.load(raw)
        for e in json_obj['d']:
            self.canonical_device_list.append(e['slug'])

def usage():
    print ("Usage: " + script_name + " [OPTIONS]\n")
    print ("\t-h Display usage")
    print ("\t-e ESR version (e.g 2021.01). Required.")
    print ("\t-b BalenaOS version (e.g 2.68). Required.")
    print ("\t-u Jenkins user name. If provided along with a Jenkins API token, deploy jobs for the specified environment will be run.")
    print ("\t-t Jenkins API token. If provided along with a Jenkins username, deploy jobs for the specified environment will be run.")
    print ("\t-d Balena deploy environment (defaults to staging).")
    print ("\t-a Balena API token with access to balena_os organization. If provided, private device types will be considered for deploy jobs.")
    print ("\t-g Github API token (for meta-balena https git access). If omitted, username and password credentials will be prompted for.")
    print ("\t-k Keep temporary directory (testing only).\n")
    sys.exit(1)

def main(argv):
    logger.setLevel(logging.INFO)
    formatter = logging.Formatter('%(asctime)s - %(name)s - %(levelname)s - %(message)s')
    lf = logging.FileHandler(os.path.basename(__file__) + str(int(time.time())) + '.log')
    lf.setLevel(logging.DEBUG)
    lf.setFormatter(formatter)
    logger.addHandler(lf)
    ch = logging.StreamHandler()
    ch.setLevel(logging.INFO)
    ch.setFormatter(formatter)
    logger.addHandler(ch)

    try:
        opts, args = getopt(argv[1:], "he:b:u:t:d:a:g:k", ["help", "esr-version=", "bos-version=", "user=", "token=", "deploy-to=", "api-token=", "github-api-token=", "keep-tmp-dir"])
    except GetoptError as ex:
        logger.error("get opt error: %s" % (str(ex)))
        usage()

    arg_dict = {}
    arg_dict["path"] = None
    arg_dict["keepTmpDir"] = False
    arg_dict["jenkins-user"] = None
    arg_dict["jenkins-token"] = None
    arg_dict["deploy-environment"] = "staging"
    arg_dict["api-token"] = None
    for o, a in opts:
        if o in ("-h", "--help"):
            usage()
        elif o in ("-e", "--esr-version"):
            arg_dict["esrVersion"] = str(a)
        elif o in ("-b", "--bos-version"):
            arg_dict["bOSVersion"] = str(a)
        elif o in ("-u", "--user"):
            arg_dict["jenkins-user"] = str(a)
        elif o in ("-t", "--token"):
            arg_dict["jenkins-token"] = str(a)
        elif o in ("-d", "--deploy-to"):
            arg_dict["deploy-environment"] = str(a)
        elif o in ("-a", "--api-token"):
            arg_dict["api-token"] = str(a)
        elif o in ("-g", "--github-api-token"):
            arg_dict["github-token"] = str(a)
        elif o in ("-k", "--keep-tmp-dir"):
            arg_dict["keepTmpDir"] = True
        else:
            assert False, "unhandled option"

    try:
        if arg_dict['esrVersion'] == None or arg_dict['bOSVersion'] == None:
            logger.error ("Both --esr-version and --bos-version are required")
            usage()
    except KeyError:
        usage()
        pass

    devices = Devices(arg_dict)

    if arg_dict['keepTmpDir'] == True:
        tmpDir = tempfile.mkdtemp()
        create_esr_branches(tmpDir, arg_dict, devices)
    else:
        with tempfile.TemporaryDirectory() as tmpDir:
            create_esr_branches(tmpDir, arg_dict, devices)

    devices.build_devices()

def apply_esr_changes(arg_dict):
    try:
        if arg_dict["path"] == None:
            arg_dict["path"] = "."
        thispath = arg_dict["path"]
        if ( not os.path.isfile(thispath + os.sep + 'VERSION') or
             not os.path.isfile(thispath + os.sep + 'CHANGELOG.md') or
             not os.path.isfile(thispath + os.sep + 'repo.yml')):
            logger.error ("Not a device repository")
            return False

        # Change into the meta-balena directory
        with pushd(thispath + os.sep + 'layers' + os.sep + 'meta-balena'):
            if not os.path.isfile(thispath + os.sep + 'repo.yml'):
                logger.error ("Missing repo.yml in " + os.getcwd())
                return False
            yaml_modify_repo(thispath + os.sep + 'repo.yml', arg_dict["bOSVersion"], arg_dict["esrVersion"])

        if yaml_modify_repo(thispath + os.sep + 'repo.yml', None, arg_dict["esrVersion"]):
            if modify_ESR_version(thispath + os.sep + 'VERSION', arg_dict["esrVersion"]):
                modify_ESR_changelog(thispath + os.sep + 'CHANGELOG.md', arg_dict["esrVersion"])
        else:
            logger.warn ("ESR version already defined")
    except KeyError:
        logger.error ("Both --esr-version and --bos-version are required")
        usage()
        pass

def check_bos_version(version):
    pattern = re.compile("^[0-9]+\.[0-9]+$")
    if not pattern.match(version):
        return False
    return True

def check_bsp_branch(branch):
    pattern = re.compile("^[1-3][0-9]{3}\.[0-1][0-9]\.x$")
    if not pattern.match(branch):
        logger.info ("Invalid branch pattern " + branch)
        return False
    return True

def check_esr_version(version):
    pattern = re.compile("^[1-3][0-9]{3}\.[0-1][0-9]$")
    if not pattern.match(version):
        return False
    return True

def generate_repo_list(organization="balena-os", token=None):
    repo_list = []
    apiEnv = "github.com/"
    page = 1
    header = { 'Authorization': "bearer " + token, 'Accept': 'application/vnd.github.v3+json' }
    while True:
        url = "https://api." + apiEnv + "orgs/" + organization + "/repos?type=all&per_page=100&page=" + str(page)
        raw = urllib.request.urlopen(urllib.request.Request(url, headers=header))
        json_obj = json.load(raw)
        if len(json_obj) == 0:
            break
        for e in json_obj:
            # Convention: All device repositories have a "https://www.balena.io/os/" homepage.
            if e['homepage'] and "balena.io/os" in e['homepage']:
                if "balena-os/balena-" in e['full_name']:
                    repo_list.append(e['ssh_url'])
        page += 1
    return repo_list

def create_esr_branches(tmpDir, arg_dict, devices):
    os.chdir(tmpDir)
    logger.info ("Working in " + tmpDir)
    repo_list = generate_repo_list(token=arg_dict['github-token'])
    for url in repo_list:
        url = url.rstrip()
        repoDir = tmpDir + os.sep + os.path.splitext(os.path.basename(url))[0]
        r = DeviceRepo(remote=url, recurse=True, version=arg_dict['bOSVersion'], path=repoDir, token=arg_dict['github-token'])
        r.clone()

        with pushd(r.path):
            esr_branch = arg_dict['esrVersion'] + '.x'
            esr_version = "v" + arg_dict['esrVersion'] + '.0'
            if r.branch_exists(esr_branch):
                esr_version = r.find_highest_tag(arg_dict['esrVersion'])
                devices.set_device_types(esr_version)
                logger.info ("ESR branch " + esr_branch + " already exists in " + url + " at " + esr_version )
                continue
            devices.set_device_types(esr_version)
            with pushd(r.path + os.sep + 'layers' + os.sep + 'meta-balena'):
                if not os.path.isfile(os.getcwd() + os.sep + 'repo.yml'):
                    logger.error ("missing repo.yml in " + os.getcwd())
                    return false
                meta_balena_esr_branch = arg_dict["bOSVersion"] + '.x'
                r.branch_or_checkout(name=meta_balena_esr_branch, path=os.getcwd())
            r.branch_or_checkout(name=esr_branch, path=os.getcwd())
            apply_esr_changes(arg_dict)
            with pushd(r.path + os.sep + 'layers' + os.sep + 'meta-balena'):
                if not os.path.isfile(os.getcwd() + os.sep + 'repo.yml'):
                    logger.error ("missing repo.yml in " + os.getcwd())
                    return false
                r.commit(message="Declare ESR " + arg_dict['bOSVersion'], path=os.getcwd())
                r.push(branch=meta_balena_esr_branch, path=os.getcwd())
            r.commit(message="Declare ESR " + arg_dict['esrVersion'], path=os.getcwd())
            version = "v" + arg_dict['esrVersion'] + ".0"
            r.tag(version, "HEAD", os.getcwd(), "Declare ESR " + arg_dict['esrVersion'])
            r.push(branch=esr_branch, path=os.getcwd())
            r.push(branch=version, path=os.getcwd())

def modify_ESR_changelog(filePath="./CHANGELOG.md", esrVersion=""):
    if not check_esr_version(esrVersion):
        logger.info ("Invalid ESR version: " + esrVersion)
        return False
    with open(filePath, 'r') as original: data = original.readlines()
    if "Change log\n" in data[0]:
        prefix = data[0:2]
        content = data[2:]
        date = datetime.now().strftime('%Y-%m-%d')
        new = "\n# " + esrVersion + ".0\n" + "## (" + date + ")\n\n* Declare ESR " + esrVersion + ".0\n"
        prefix.append(new)
        prefix.append("".join(content))
        with open(filePath, 'w') as modified: modified.write("".join(prefix))
    else:
        logger.error("Not a changelog file.")

def modify_ESR_version(filePath="./VERSION", esrVersion=""):
    if not check_esr_version(esrVersion):
        logger.info ("Invalid ESR version: " + esrVersion)
        return False
    with open(filePath, 'r') as original: data = original.read()
    (data, count) = re.subn("^\d+\.\d+.\d+\+rev\d+$", esrVersion + ".0", data)
    if count != 1:
        logger.error ("Error in VERSION file")
        return False
    with open(filePath, 'w') as modified:  modified.write(data)
    return True

@contextlib.contextmanager
def pushd(ndir):
        pdir = os.getcwd()
        os.chdir(ndir)
        try:
                yield
        finally:
                os.chdir(pdir)

def yaml_modify_repo(filePath="./repo.yml", bosVersion="", esrVersion=""):
    if esrVersion != None:
        if not check_esr_version(esrVersion):
            logger.info ("Invalid ESR version " + esrVersion)
            return False

    with open(filePath, 'r') as original: ydata = yaml.safe_load(original)

    if 'esr' in ydata:
        # Silent return
        return False

    if bosVersion != None:
        # Modifying meta-balena
        if not check_bos_version(bosVersion):
            logger.info ("Invalid balenaOS version " + bosVersion)
            return False
        branch = esrVersion + ".x"
        if not check_bsp_branch(branch):
            return False
        ydata['esr'] =  { 'version': bosVersion, 'bsp-branch-pattern': branch }
    else:
        # Modifying device repository
        ydata['esr'] =  { 'version': esrVersion }

    with open(filePath, 'w') as modified: yaml.dump(ydata, modified)
    return True

if __name__ == '__main__':
    script_name = sys.argv[0]
    main(sys.argv)
