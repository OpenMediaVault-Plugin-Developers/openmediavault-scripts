<?php
/**
 * Copyright (C) 2024 OpenMediaVault Plugin Developers
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

        $this->registerMethod('getJobList');
        $this->registerMethod('getJob');
        $this->registerMethod('setJob');
        $this->registerMethod('deleteJob');
        $this->registerMethod('doJob');
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
        $objects = $db->getAssoc('conf.service.scripts.file');
        // Filter the result.
        return $this->applyFilter($objects, $params['start'], $params['limit'],
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
        $scriptFile = sprintf('%s/%s.%s', $sfpath, $object->get('name'), $object->get('ext'));
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
        // Get the configuration object.
        $db = \OMV\Config\Database::getInstance();
        $script = $db->get('conf.service.scripts.file', $params['uuid']);
        $sfpath = $this->getScriptsPath($context);
        return $this->execBgProc(function($bgStatusFilename, $bgOutputFilename)
            use ($script, $params, $sfpath) {
                $output = [];
                $scriptFile = sprintf('%s/%s.%s', $sfpath, $script->get('name'), $script->get('ext'));
                if (file_exists($scriptFile)) {
                    $cmd = new \OMV\System\Process($scriptFile);
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
        $object = $db->get('conf.service.scripts.job', $params['uuid']);
        return $object->getAssoc();
    }

    public function setJob($params, $context)
    {
        // Validate the RPC caller context.
        $this->validateMethodContext($context, ['role' => OMV_ROLE_ADMINISTRATOR]);
        // Validate the parameters of the RPC service method.
        $this->validateMethodParams($params, 'rpc.scripts.setjob');
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
}
