<?php
/**
 * Copyright (C) 2024-2025 OpenMediaVault Plugin Developers
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program. If not, see <http://www.gnu.org/licenses/>.
 */

class OMVRpcServiceScripts extends \OMV\Rpc\ServiceAbstract
{
    public function getName()
    {
        return 'Scripts';
    }

    public function initialize()
    {
        $this->registerMethod('get');
        $this->registerMethod('set');

        $this->registerMethod('getScriptList');
        $this->registerMethod('enumerateScripts');
        $this->registerMethod('getScript');
        $this->registerMethod('setScript');
        $this->registerMethod('deleteScript');
        $this->registerMethod('doRun');
        $this->registerMethod('doCheck');
        $this->registerMethod('addUrl');
        $this->registerMethod("importChanges");
        $this->registerMethod('importExistingFolder');
        $this->registerMethod('importExistingOne');
        $this->registerMethod('doGit');

        $this->registerMethod('getJobList');
        $this->registerMethod('getJob');
        $this->registerMethod('setJob');
        $this->registerMethod('deleteJob');
        $this->registerMethod('doJob');

        $this->registerMethod('getLogList');
        $this->registerMethod('deleteLog');
        $this->registerMethod('viewLog');
    }

    private function getScriptsPath($context)
    {
        // Get configuration data.
        $db = \OMV\Config\Database::getInstance();
        // Get sharedfolder path
        $sfobject = $db->get('conf.service.scripts');
        $sfref = $sfobject->get('sharedfolderref');
        $sfpath = '';
        if (is_uuid($sfref)) {
            $sfpath = \OMV\Rpc\Rpc::call('ShareMgmt', 'getPath', ['uuid' => $sfref], $context);
            $sfpath = rtrim($sfpath, '/');
        } else {
            throw new \OMV\Exception(gettext('Please set shared folder for script storage.'));
        }
        return ($sfpath);
    }

    private function addAndCommit($context, $files, $msg)
    {
        $sfpath = $this->getScriptsPath($context);
        if (is_dir(sprintf("%s/.git", $sfpath))) {
            // git add to repo
            $cmdArgs = [];
            $cmdArgs[] = sprintf("-C '%s'", $sfpath);
            $cmdArgs[] = 'add';
            $cmdArgs = array_merge($cmdArgs, $files);
            $cmd = new \OMV\System\Process('git', $cmdArgs);
            $cmd->setQuiet(true);
            $cmd->execute($output, $exitStatus);
            // git commit change
            $cmdArgs = [];
            $cmdArgs[] = sprintf("-C '%s'", $sfpath);
            $cmdArgs[] = 'commit';
            $cmdArgs[] = sprintf("-m 'Updated %s on %s'", $msg, date('Y.m.d h:i:sa'));
            $cmd = new \OMV\System\Process('git', $cmdArgs);
            $cmd->setQuiet(true);
            $cmd->execute($output, $exitStatus);
        }
    }

    private function removeAndCommit($context, $files, $msg)
    {
        $sfpath = $this->getScriptsPath($context);
        if (is_dir(sprintf("%s/.git", $sfpath))) {
            // git add to repo
            $cmdArgs = [];
            $cmdArgs[] = sprintf("-C '%s'", $sfpath);
            $cmdArgs[] = 'rm';
            $cmdArgs[] = '-f';
            $cmdArgs = array_merge($cmdArgs, $files);
            $cmd = new \OMV\System\Process('git', $cmdArgs);
            $cmd->setQuiet(true);
            $cmd->execute($output, $exitStatus);
            // git commit change
            $cmdArgs = [];
            $cmdArgs[] = sprintf("-C '%s'", $sfpath);
            $cmdArgs[] = 'commit';
            $cmdArgs[] = sprintf("-m 'Removed %s on %s'", $msg, date('Y.m.d h:i:sa'));
            $cmd = new \OMV\System\Process('git', $cmdArgs);
            $cmd->setQuiet(true);
            $cmd->execute($output, $exitStatus);
        }
    }

    public function get($params, $context)
    {
        // Validate the RPC caller context.
        $this->validateMethodContext($context, ['role' => OMV_ROLE_ADMINISTRATOR]);
        // Get the configuration object.
        $db = \OMV\Config\Database::getInstance();
        $object = $db->get('conf.service.scripts');
        // Remove useless properties from the object.
        $object->remove('files');
        $object->remove('jobs');
        // Return the configuration object.
        return $object->getAssoc();
    }

    public function set($params, $context)
    {
        // Validate the RPC caller context.
        $this->validateMethodContext($context, ['role' => OMV_ROLE_ADMINISTRATOR]);
        // Validate the parameters of the RPC service method.
        $this->validateMethodParams($params, 'rpc.scripts.set');
        // Get the existing configuration object.
        $db = \OMV\Config\Database::getInstance();
        $object = $db->get('conf.service.scripts');
        $object->setAssoc($params);
        $db->set($object);
        // Remove useless properties from the object.
        $object->remove('files');
        $object->remove('jobs');
        // Return the configuration object.
        return $object->getAssoc();
    }

    public function getScriptList($params, $context)
    {
        // Validate the RPC caller context.
        $this->validateMethodContext($context, ['role' => OMV_ROLE_ADMINISTRATOR]);
        // Validate the parameters of the RPC service method.
        $this->validateMethodParams($params, 'rpc.common.getlist');
        // Get configuration data.
        $db = \OMV\Config\Database::getInstance();
        $objects = $db->get('conf.service.scripts.file');
        // Add additional script info
        $sfpath = $this->getScriptsPath($context);
        $objectsAssoc = [];
        foreach ($objects as $objectk => &$objectv) {
            $fullpath = sprintf('%s/%s.%s', $sfpath, $objectv->get('name'), $objectv->get('ext'));
            $objectv->add('fullpath', 'string', $fullpath);
            $filesize = filesize($fullpath);
            if ($filesize !== false && $filesize > -1) {
                $objectv->add('filesize', 'integer', $filesize);
            }
            $assoc = $objectv->getAssoc();
            unset($assoc['body']);
            $objectsAssoc[] = $assoc;
        }
        // Filter the result.
        return $this->applyFilter($objectsAssoc, $params['start'], $params['limit'],
            $params['sortfield'], $params['sortdir'], $params['search']);
    }

    public function enumerateScripts($params, $context)
    {
        // Validate the RPC caller context.
        $this->validateMethodContext($context, ['role' => OMV_ROLE_ADMINISTRATOR]);
        // Get configuration data.
        $db = \OMV\Config\Database::getInstance();
        $objects = $db->getAssoc('conf.service.scripts.file');
        // Filter the result.
        return ($objects);
    }

    public function getScript($params, $context)
    {
        // Validate the RPC caller context.
        $this->validateMethodContext($context, ['role' => OMV_ROLE_ADMINISTRATOR]);
        // Validate the parameters of the RPC service method.
        $this->validateMethodParams($params, 'rpc.common.objectuuid');
        // Get the configuration object.
        $db = \OMV\Config\Database::getInstance();
        return $db->getAssoc('conf.service.scripts.file', $params['uuid']);
    }

    public function setScript($params, $context)
    {
        // Validate the RPC caller context.
        $this->validateMethodContext($context, ['role' => OMV_ROLE_ADMINISTRATOR]);
        // Validate the parameters of the RPC service method.
        $this->validateMethodParams($params, 'rpc.scripts.setscript');
        // Verify that shared folder is set
        $db = \OMV\Config\Database::getInstance();
        $sfpath = $this->getScriptsPath($context);
        // Prepare the configuration object.
        $object = new \OMV\Config\ConfigObject('conf.service.scripts.file');
        $object->setAssoc($params);
        // Set the configuration object.
        $isNew = $object->isNew();
        if (TRUE === $isNew) {
            // Check uniqueness - name
            $db->assertIsUnique($object, 'name');
        }
        $db->set($object);
        // Apply changes immmediately
        \OMV\Rpc\Rpc::call('Config', 'applyChanges', [
            'modules' => [ 'scripts' ],
            'force' => TRUE
        ], $context);
        // add and commit to git if repo exists
        $file = sprintf("%s.%s", $params['name'], $params['ext']);
        $this->addAndCommit($context, [$file], $file);
        // Return the configuration object.
        return $object->getAssoc();
    }

    public function deleteScript($params, $context)
    {
        // Validate the RPC caller context.
        $this->validateMethodContext($context, ['role' => OMV_ROLE_ADMINISTRATOR]);
        // Validate the parameters of the RPC service method.
        $this->validateMethodParams($params, 'rpc.common.objectuuid');
        // Verify that shared folder is set
        $db = \OMV\Config\Database::getInstance();
        $sfpath = $this->getScriptsPath($context);
        $uuid = $params['uuid'];
        // Delete jobs for this script
        $jobs = $db->get('conf.service.scripts.job');
        foreach ($jobs as $job) {
            $scriptref = $job->get('script');
            if ($scriptref == $uuid) {
                $deljob = $db->get('conf.service.scripts.job', $job->get('uuid'));
                $db->delete($deljob);
            }
        }
        // Delete the configuration object.
        $object = $db->get('conf.service.scripts.file', $params['uuid']);
        // remove file from git and delete file
        $file = sprintf('%s.%s', $object->get('name'), $object->get('ext'));
        $scriptFile = sprintf('%s/%s', $sfpath, $file);
        $this->removeAndCommit($context, [$file], $file);
        if (file_exists($scriptFile)) {
            unlink($scriptFile);
        }
        $db->delete($object);
        // Return the deleted configuration object.
        return $object->getAssoc();
    }

    public function doRun($params, $context)
    {
        // Validate the RPC caller context.
        $this->validateMethodContext($context, ['role' => OMV_ROLE_ADMINISTRATOR]);
        // Validate the parameters of the RPC service method.
        $this->validateMethodParams($params, 'rpc.common.objectuuid');
        // Get the configuration object.
        $db = \OMV\Config\Database::getInstance();
        $script = $db->get('conf.service.scripts.file', $params['uuid']);
        $sfpath = $this->getScriptsPath($context);
        return $this->execBgProc(function($bgStatusFilename, $bgOutputFilename)
            use ($script, $sfpath) {
                $output = [];
                $scriptFile = sprintf('%s/%s.%s', $sfpath, $script->get('name'), $script->get('ext'));
                if (file_exists($scriptFile)) {
                    $cmdArgs = [];
                    $cmdArgs[] = '/usr/sbin/omv-scripts-exec-wrapper';
                    $cmdArgs[] = $scriptFile;
                    if (strlen($script->get('testargs')) > 0) {
                        $cmdArgs[] = $script->get('testargs');
                    }
                    $cmd = new \OMV\System\Process($cmdArgs);
                    $cmd->setRedirect2to1();
                    $cmdLine = $cmd->getCommandLine();
                    if (0 !== $this->exec($cmdLine, $output, $bgOutputFilename)) {
                        throw new \OMV\ExecException($cmdLine, $output);
                    }
                }
                return $output;
            }
        );
    }

    public function doCheck($params, $context)
    {
        // Validate the RPC caller context.
        $this->validateMethodContext($context, ['role' => OMV_ROLE_ADMINISTRATOR]);
        // Validate the parameters of the RPC service method.
        $this->validateMethodParams($params, 'rpc.common.objectuuid');
        // Get the configuration object.
        $db = \OMV\Config\Database::getInstance();
        $script = $db->get('conf.service.scripts.file', $params['uuid']);
        $sfpath = $this->getScriptsPath($context);
        return $this->execBgProc(function($bgStatusFilename, $bgOutputFilename)
            use ($script, $sfpath) {
                $output = [];
                $scriptFile = sprintf('%s/%s.%s', $sfpath, $script->get('name'), $script->get('ext'));
                if (file_exists($scriptFile)) {
                    $cmdArgs = [];
                    switch ($script->get('ext')) {
                        case 'sh':
                        case 'ksh':
                            file_put_contents($bgOutputFilename, 'Using shellcheck ...' . PHP_EOL . PHP_EOL, FILE_APPEND);
                            $cmdArgs[] = 'shellcheck';
                            break;
                        case 'py':
                            file_put_contents($bgOutputFilename, 'Using pylint ...' . PHP_EOL . PHP_EOL, FILE_APPEND);
                            $cmdArgs[] = 'pylint';
                            break;
                    }
                    $cmdArgs[] = $scriptFile;
                    $cmd = new \OMV\System\Process($cmdArgs);
                    $cmd->setRedirect2to1();
                    $cmdLine = $cmd->getCommandLine();
                    if (0 == $this->exec($cmdLine, $output, $bgOutputFilename)) {
                        file_put_contents($bgOutputFilename, 'No errors found.' . PHP_EOL, FILE_APPEND);
                    }
                }
                return $output;
            }
        );
    }

    public function addUrl($params, $context)
    {
        // Validate the RPC caller context.
        $this->validateMethodContext($context, ['role' => OMV_ROLE_ADMINISTRATOR]);
        // Validate the parameters of the RPC service method.
        $this->validateMethodParams($params, 'rpc.scripts.addurl');
        // Verify that shared folder is set
        $sfpath = $this->getScriptsPath($context);
        // download script
        $url = $params['url'];
        $script = file_get_contents($url);
        // Put script in a temp file
        if ($script !== false) {
            if ($params['name'] == '') {
                $name = pathinfo($url, PATHINFO_FILENAME);
            } else {
                $name = $params['name'];
            }
            $ext = pathinfo($url, PATHINFO_EXTENSION);
            $tmpname = tempnam(sys_get_temp_dir(), "omv_scripts_");
            unlink($tmpname);
            $tmp = sprintf('%s.%s', $tmpname, $ext);
            file_put_contents($tmp, $script);
            $exts = ['sh', 'ksh', 'py', 'conf', 'txt'];
            if (!in_array($ext, $exts)) {
                $ext = $this->getExtForFile($tmp);
            }
            // remove temp file
            unlink($tmp);
            if (in_array($ext, $exts)) {
                // set object values
                $db = \OMV\Config\Database::getInstance();
                $object = new \OMV\Config\ConfigObject("conf.service.scripts.file");
                $object->set('name', $name);
                $object->set('ext', $ext);
                $object->set('body', trim($script));
                $object->set('testargs', '');
                // Set the configuration object.
                $db->assertIsUnique($object, 'name');
                $db->set($object);
            }
        }
    }

    public function importChanges($params, $context)
    {
        // Validate the RPC caller context.
        $this->validateMethodContext($context, ["role" => OMV_ROLE_ADMINISTRATOR]);
        // Validate the parameters of the RPC service method.
        $this->validateMethodParams($params, 'rpc.common.objectuuid');
        // Get the configuration object.
        $db = \OMV\Config\Database::getInstance();
        $script = $db->get('conf.service.scripts.file', $params['uuid']);
        $sfpath = $this->getScriptsPath($context);
        $scriptFile = sprintf('%s/%s.%s', $sfpath, $script->get('name'), $script->get('ext'));
        if (file_exists($scriptFile)) {
            // Get file content
            $body = trim(file_get_contents($scriptFile));
            // Update object
            $script->set('body', $body);
            // Set the configuration object.
            $db->set($script);
        }
        // Return the configuration object.
        return $script->getAssoc();
    }

    public function importExistingFolder($params, $context)
    {
        // Validate the RPC caller context.
        $this->validateMethodContext($context, ['role' => OMV_ROLE_ADMINISTRATOR]);
        // Validate the parameters of the RPC service method.
        $this->validateMethodParams($params, 'rpc.scripts.import');
        // Verify that shared folder is set
        $sfpath = $this->getScriptsPath($context);
        // Get the configuration object.
        $db = \OMV\Config\Database::getInstance();
        $path = $params['path'];
        $path = (substr($path, 0, 1) == '/' ? $path : '/' . $path);
        $path = rtrim($path, '/');
        // get files with sh, ksh, or py extensions
        $sh = glob($path . "/*.sh");
        $ksh = glob($path . "/*.ksh");
        $py = glob($path . "/*.py");
        $conf = glob($path . "/*.conf");
        $txt = glob($path . "/*.txt");
        // get files in path that have no extension but have a shell or python shebang
        $cmdArgs = [];
        $cmdArgs[] = 'grep';
        $cmdArgs[] = '-l';
        $cmdArgs[] = '-E \'^#!/(bin|usr/bin)/(bash|sh|ksh|python)|^#!/usr/bin/env (python|sh|bash|ksh)\'';
        $cmdArgs[] = sprintf('%s/*', $path);
        $cmdArgs[] = '| awk NF';
        $cmd = new \OMV\System\Process($cmdArgs);
        $cmd->execute($search);
        // combine lists and make unique
        $all = array_merge($sh, $ksh, $py, $conf, $txt, $search);
        $allu = array_unique(array_filter($all));
        foreach ($allu as $script) {
            if (!is_file($script)) {
                continue;
            }
            $name = pathinfo($script, PATHINFO_FILENAME);
            $ext = pathinfo($script, PATHINFO_EXTENSION);
            if ($ext == '') {
                $ext = $this->getExtForFile($script);
            }
            $body = trim(file_get_contents($script));
            // set object values
            $object = new \OMV\Config\ConfigObject("conf.service.scripts.file");
            $object->set('name', $name);
            $object->set('ext', $ext);
            $object->set('body', $body);
            $object->set('testargs', '');
            // Set the configuration object.
            try {
                $db->assertIsUnique($object, 'name');
            } catch (Exception $e) {
                continue;
            }
            $db->set($object);
        }
    }

    public function importExistingOne($params, $context)
    {
        // Validate the RPC caller context.
        $this->validateMethodContext($context, ['role' => OMV_ROLE_ADMINISTRATOR]);
        // Validate the parameters of the RPC service method.
        $this->validateMethodParams($params, 'rpc.scripts.import');
        // Verify that shared folder is set
        $sfpath = $this->getScriptsPath($context);
        // Get the configuration object.
        $db = \OMV\Config\Database::getInstance();
        $path = $params['path'];
        $path = '/' . ltrim($path, '/');
        if (!is_file($path)) {
            throw new \OMV\ExecException(gettext('Specified path is not a file!'));
        }
        $ext = pathinfo($path, PATHINFO_EXTENSION);
        $exts = ['sh', 'ksh', 'py', 'conf', 'txt'];
        if (!in_array($ext, $exts)) {
            $ext = $this->getExtForFile($path);
        }
        if (in_array($ext, $exts)) {
            $name = pathinfo($path, PATHINFO_FILENAME);
            $body = trim(file_get_contents($path));
            // set object values
            $object = new \OMV\Config\ConfigObject("conf.service.scripts.file");
            $object->set('name', $name);
            $object->set('ext', $ext);
            $object->set('body', $body);
            $object->set('testargs', '');
            // Set the configuration object.
            $db->assertIsUnique($object, 'name');
            $db->set($object);
        }
    }

    private function getExtForFile($path)
    {
        $ext = 'txt';
        // search shebangs for script types
        $search = ['/sh', '/bash', '/ksh', '/python', 'env sh', 'env bash', 'env ksh', 'env python'];
        // Read the first line of the file
        $line1 = trim(fgets(fopen($path, 'r')));
        foreach ($search as $pattern) {
            if (strpos($line1, $pattern) !== false) {
                switch ($pattern) {
                    case '/sh':
                    case '/bash':
                    case 'env sh':
                    case 'env bash':
                        $ext = 'sh';
                        break;
                    case '/ksh':
                    case 'env ksh':
                        $ext = 'ksh';
                        break;
                    case '/python':
                    case 'env python':
                        $ext = 'py';
                        break;
                }
                break;
            }
        }
        return ($ext);
    }

    public function doGit($params, $context)
    {
        // Validate the RPC caller context.
        $this->validateMethodContext($context, ["role" => OMV_ROLE_ADMINISTRATOR]);
        // Get the configuration object.
        $db = \OMV\Config\Database::getInstance();
        $object = false;
        if (is_uuid($params['uuid'])) {
            $object = $db->get("conf.service.scripts.file", $params['uuid']);
        }
        $sfpath = $this->getScriptsPath($context);
        return $this->execBgProc(function($bgStatusFilename, $bgOutputFilename)
            use ($object, $params, $sfpath, $db) {
                $cmdArgs = [];
                switch ($params['command']) {
                    case 'init':
                        $cmdArgs = [];
                        $cmdArgs[] = sprintf("'%s'", $sfpath);
                        $cmd = new \OMV\System\Process('omv-scripts-init-git', $cmdArgs);
                        break;
                    case 'diff':
                        if (!$object)
                            return [];

                        $script = $object->get('name');
                        $ext = $object->get('ext');

                        $cmdArgs = [];
                        $cmdArgs[] = sprintf("-C '%s'", $sfpath);
                        $cmdArgs[] = 'log';
                        $cmdArgs[] = '-p';
                        $cmdArgs[] = '--';
                        $cmdArgs[] = sprintf('%s.%s', $script, $ext);
                        $cmd = new \OMV\System\Process('git', $cmdArgs);
                        break;
                }
                $cmd->setRedirect2to1();
                $cmd->setQuiet(true);
                $cmdLine = $cmd->getCommandLine();
                file_put_contents($bgOutputFilename, $cmdLine . PHP_EOL . PHP_EOL, FILE_APPEND);
                $exitStatus = $this->exec($cmdLine, $output, $bgOutputFilename);
                if ($exitStatus !== 0) {
                    $errmsg = PHP_EOL . PHP_EOL . '*** ERROR #' . $exitStatus . ' ***' . PHP_EOL . PHP_EOL;
                    file_put_contents($bgOutputFilename, $errmsg, FILE_APPEND);
                }
                return $output;
            }
        );
    }

    public function getJobList($params, $context)
    {
        // Validate the RPC caller context.
        $this->validateMethodContext($context, ['role' => OMV_ROLE_ADMINISTRATOR]);
        // Validate the parameters of the RPC service method.
        $this->validateMethodParams($params, 'rpc.common.getlist');
        // Get configuration data.
        $db = \OMV\Config\Database::getInstance();
        $objects = $db->get('conf.service.scripts.job');
        // Add additional script info
        $objectsAssoc = [];
        foreach ($objects as $objectk => &$objectv) {
            $script = $db->get('conf.service.scripts.file', $objectv->get('script'));
            $objectv->add('scriptname', 'string', $script->get('name'));
            $objectsAssoc[] = $objectv->getAssoc();
        }
        // Filter the result.
        return $this->applyFilter($objectsAssoc, $params['start'], $params['limit'],
            $params['sortfield'], $params['sortdir'], $params['search']);
    }

    public function getJob($params, $context)
    {
        // Validate the RPC caller context.
        $this->validateMethodContext($context, ['role' => OMV_ROLE_ADMINISTRATOR]);
        // Validate the parameters of the RPC service method.
        $this->validateMethodParams($params, 'rpc.common.objectuuid');
        // Get the configuration object.
        $db = \OMV\Config\Database::getInstance();
        $result = $db->getAssoc('conf.service.scripts.job', $params['uuid']);
        // Convert comma separated list into an array.
        $result['minute'] = explode(",", $result['minute']);
        $result['hour'] = explode(",", $result['hour']);
        $result['dayofmonth'] = explode(",", $result['dayofmonth']);
        $result['month'] = explode(",", $result['month']);
        $result['dayofweek'] = explode(",", $result['dayofweek']);
        return $result;
    }

    public function setJob($params, $context)
    {
        // Validate the RPC caller context.
        $this->validateMethodContext($context, ['role' => OMV_ROLE_ADMINISTRATOR]);
        // Validate the parameters of the RPC service method.
        $this->validateMethodParams($params, 'rpc.scripts.setjob');
        // Convert array into a comma separated list.
        $params['minute'] = implode(",", $params['minute']);
        $params['hour'] = implode(",", $params['hour']);
        $params['dayofmonth'] = implode(",", $params['dayofmonth']);
        $params['month'] = implode(",", $params['month']);
        $params['dayofweek'] = implode(",", $params['dayofweek']);
        // Prepare the configuration object.
        $object = new \OMV\Config\ConfigObject('conf.service.scripts.job');
        $db = \OMV\Config\Database::getInstance();
        $object->setAssoc($params);
        // Set the configuration object.
        $db->set($object);
        // Return the configuration object.
        return $object->getAssoc();
    }

    public function deleteJob($params, $context)
    {
        // Validate the RPC caller context.
        $this->validateMethodContext($context, ['role' => OMV_ROLE_ADMINISTRATOR]);
        // Validate the parameters of the RPC service method.
        $this->validateMethodParams($params, 'rpc.common.objectuuid');
        // Delete the configuration object.
        $db = \OMV\Config\Database::getInstance();
        $object = $db->get('conf.service.scripts.job', $params['uuid']);
        $db->delete($object);
        // Return the deleted configuration object.
        return $object->getAssoc();
    }

    public function doJob($params, $context)
    {
        // Validate the RPC caller context.
        $this->validateMethodContext($context, ['role' => OMV_ROLE_ADMINISTRATOR]);
        // Validate the parameters of the RPC service method.
        $this->validateMethodParams($params, 'rpc.common.objectuuid');
        // Get the configuration object.
        $db = \OMV\Config\Database::getInstance();
        $job = $db->get('conf.service.scripts.job', $params['uuid']);
        $script = $db->get('conf.service.scripts.file', $job->get('script'));
        $sfpath = $this->getScriptsPath($context);
        return $this->execBgProc(function($bgStatusFilename, $bgOutputFilename)
            use ($job, $script, $sfpath) {
                $output = [];
                $scriptFile = sprintf('%s/%s.%s', $sfpath, $script->get('name'), $script->get('ext'));
                if (file_exists($scriptFile)) {
                    $cmdArgs = [];
                    $cmdArgs[] = '/usr/sbin/omv-scripts-exec-wrapper';
                    $cmdArgs[] = $scriptFile;
                    $args = $job->get('args');
                    if (strlen($args) > 0) {
                        $cmdArgs[] = $job->get('args');
                    }
                    $cmd = new \OMV\System\Process($cmdArgs);
                    $cmd->setRedirect2to1();
                    $cmdLine = $cmd->getCommandLine();
                    if (0 !== $this->exec($cmdLine, $output, $bgOutputFilename)) {
                        throw new \OMV\ExecException($cmdLine, $output);
                    }
                } else {
                    throw new \OMV\ExecException('Script not found - ' . $scriptFile);
                }
                return $output;
            }
        );
    }

    public function getLogList($params, $context)
    {
        // Validate the RPC caller context.
        $this->validateMethodContext($context, ['role' => OMV_ROLE_ADMINISTRATOR]);
        // Validate the parameters of the RPC service method.
        $this->validateMethodParams($params, 'rpc.common.getlist');
        // grab the main log plus any rotated logs
        $pattern = '/var/log/omv-scripts-exec-tracker.log*';
        $logFiles = glob($pattern);
        natsort($logFiles);
        $objectsAssoc = [];
        foreach ($logFiles as $file) {
            if (!is_file($file) || !is_readable($file)) {
                continue;
            }
            // prefix with zlib wrapper if compressed
            $path = $this->isGz($file) ? "compress.zlib://{$file}" : $file;
            // read log as csv
            if ($fh = @fopen($path, 'r')) {
                while (($row = fgetcsv($fh)) !== false) {
                    list($id, $start, $stop, $script, $exitcode, $duration, $runlog, $logsize) = $row;
                    $objectsAssoc[] = [
                        'id' => $id,
                        'script' => $script,
                        'start' => $start,
                        'stop' => $stop,
                        'exitcode' => (int)$exitcode,
                        'duration' => $duration,
                        'runlog' => $runlog,
                        'logsize' => (int)$logsize,
                        'logfile' => $file
                    ];
                }
                fclose($fh);
            }
        }

        // Filter the result.
        return $this->applyFilter($objectsAssoc, $params['start'], $params['limit'],
            $params['sortfield'], $params['sortdir'], $params['search']);
    }

    public function deleteLog($params, $context)
    {
        // Validate the RPC caller context.
        $this->validateMethodContext($context, ['role' => OMV_ROLE_ADMINISTRATOR]);
        $logfile = $params['logfile'];
        $id = $params['id'];
        $gz = $this->isGz($logfile);
        if ($gz && is_readable($logfile)) {
            $tmp = sprintf('%s.tmp', $logfile);
            $in = gzopen($logfile, 'rb');
            $out = fopen($tmp, 'w');
            if ($in && $out) {
                while (!gzeof($in)) {
                    $line = gzgets($in);
                    // only write lines that do NOT start with our ID:
                    if (!preg_match("/^{$id},/", $line)) {
                        fwrite($out, $line);
                    }
                }
                gzclose($in);
                fclose($out);
                $in2 = fopen($tmp, 'rb');
                $out2 = gzopen($logfile, 'wb9');
                if ($in2 && $out2) {
                    while (!feof($in2)) {
                        gzwrite($out2, fread($in2, 8192));
                    }
                    fclose($in2);
                    gzclose($out2);
                }
                unlink($tmp);
            }
        } elseif (is_writable($logfile)) {
            // delete id from log file
            $cmdArgs = [];
            $cmdArgs[] = 'sed';
            $cmdArgs[] = '-i';
            $cmdArgs[] = sprintf("'/^%s/d'", $params['id']);
            $cmdArgs[] = '/var/log/omv-scripts-exec-tracker.log';
            $cmd = new \OMV\System\Process($cmdArgs);
            $cmd->execute($search);
        }
        // delete log file
        if (file_exists($params['runlog'])) {
            @unlink($params['runlog']);
        }
    }

    public function viewLog($params, $context)
    {
        // Validate the RPC caller context.
        $this->validateMethodContext($context, ['role' => OMV_ROLE_ADMINISTRATOR]);
        return $this->execBgProc(function($bgStatusFilename, $bgOutputFilename)
            use ($params) {
                $output = [];
                $runlog = $params['runlog'];
                // if file doesn't exist, look for logrotated version
                if (!is_readable($runlog)) {
                    $candidates = glob($runlog . '.*');
                    if ($candidates) {
                        // sort by modification time, newest first
                        usort($candidates, function($a, $b) {
                            return filemtime($b) - filemtime($a);
                        });
                        foreach ($candidates as $f) {
                            if (is_readable($f)) {
                                $runlog = $f;
                                file_put_contents($bgOutputFilename,
                                  "using logrotated log file " . $runlog .
                                  PHP_EOL . PHP_EOL, FILE_APPEND);
                                break;
                            }
                        }
                    }
                }
                if (is_readable($runlog)) {
                    $gz = $this->isGz($runlog);
                    $cmdArgs = [];
                    $cmdArgs[] = $gz ? 'zcat' : 'cat';
                    $cmdArgs[] = $runlog;
                    $cmd = new \OMV\System\Process($cmdArgs);
                    $cmd->setRedirect2to1();
                    $cmdLine = $cmd->getCommandLine();
                    if (0 !== $this->exec($cmdLine, $output, $bgOutputFilename)) {
                        throw new \OMV\ExecException($cmdLine, $output);
                    }
                } else {
                    file_put_contents($bgOutputFilename,
                      "Scripts Log Viewer - Unable to locate file ". $runlog .
                      PHP_EOL . PHP_EOL, FILE_APPEND);
                }
                return $output;
            }
        );
    }

    private function isGz($path)
    {
        $finfo = new finfo(FILEINFO_MIME_TYPE);
        $type = $finfo->file($path);
        if (in_array($type, ['application/x-gzip','application/gzip'], true)) {
            return true;
        } elseif (strpos($type, 'text/') === 0) {
            return false;
        } else {
            throw new \OMV\Exception('bad file ' . $path);
        }
    }
}
