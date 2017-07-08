function net = faster_rcnn_init(opts, varargin)
% FASTER_RCNN_INIT Initialize a Faster R-CNN Detector Network
DEBUG = 0 ;

if DEBUG
  net = load('cNet.mat') ; 
  net = Net(net) ;
  return
end

modelName = opts.modelOpts.architecture ;
modelDir = fullfile(vl_rootnn, 'data/models-import') ;

switch modelName
  case 'vgg16'
    trunkPath = fullfile(modelDir, 'imagenet-vgg-verydeep-16.mat') ;
    rootUrl = 'http://www.vlfeat.org/matconvnet/models' ;
    trunkUrl = [rootUrl '/imagenet-vgg-verydeep-16.mat' ] ;
  case 'vgg16-reduced'
    trunkPath = fullfile(modelDir, 'vgg-vd-16-reduced.mat') ;
    rootUrl = 'http://www.robots.ox.ac.uk/~albanie/models' ;
    trunkUrl = [rootUrl '/ssd/vgg-vd-16-reduced.mat'] ;
  case 'resnet50'
    error('%s not yet supported', modelName) ;
  case 'resnext101_64x4d'
    error('%s not yet supported', modelName) ;
  otherwise
    error('architecture %d is not recognised', modelName) ;
end

if ~exist(trunkPath, 'file')
  fprintf('%s not found, downloading... \n', opts.modelOpts.architecture) ;
  mkdir(fileparts(opts.modelPath)) ; urlwrite(trunkUrl, trunkPath) ;
end

net = vl_simplenn_tidy(load(trunkPath)) ; net = dagnn.DagNN.fromSimpleNN(net) ;

% modify trunk biases learnning rate and weight decay to match caffe 
params = {'conv1_1b', 'conv1_2b', 'conv2_1b', 'conv2_2b', 'conv3_1b', ...
          'conv3_2b', 'conv3_3b', 'conv4_1b', 'conv4_2b', 'conv4_3b' ...
          'conv5_1b', 'conv5_2b', 'conv5_3b' 'fc6b', 'fc7b' } ;
for i = 1:length(params), net = matchCaffeBiases(net, params{i}) ; end

if strcmp(opts.modelOpts.architecture, 'vgg16-reduced') % match caffe
  net.layers(net.getLayerIndex('fc6')).block.dilate = [6 6] ;
  net.layers(net.getLayerIndex('fc6')).block.pad = [6 6] ;
  net.layers(net.getLayerIndex('pool5')).block.stride = [1 1] ;
  net.layers(net.getLayerIndex('pool5')).block.poolSize = [3 3] ;
  net.layers(net.getLayerIndex('pool5')).block.pad = [1 1 1 1] ;
end
net.removeLayer('fc8') ; net.removeLayer('prob') ; net.renameVar('x0', 'data') ;

rng(0) ; % for reproducibility, fix the seed

% configure autonn inputs
%data = Input('data') ; 
gtBoxes = Input('gtBoxes') ; 
gtLabels = Input('gtLabels') ; imInfo = Input('imInfo') ;
%epoch = Input('epoch') ; % epoch only used for tukey/mAP

if opts.modelOpts.batchRenormalization % additional input for batch renorm
  clips = Input('clips') ; opts.clips = clips ;
  LR = {'learningRate', [2 1 opts.modelOpts.alpha]} ;opts.renormLR = LR ; 
end

%mNet = load('data/models-import/faster-rcnn-vggvd-pascal.mat') ;
%mDag = dagnn.DagNN.loadobj(mNet) ;
%nDag = net ;

%for ii = 1:numel(mDag.layers)
  %if ii > numel(nDag.layers), l = '-' ; else, l = nDag.layers(ii).name ; end
  %fprintf('nDag layer name: %s\n', l) ;
  %fprintf('mDag layer name: %s\n', mDag.layers(ii).name) ;
%end

% convert to autonn
stored = Layer.fromDagNN(net) ; net = stored{1} ; % convert to autonn

% Region proposal network 
src = net.find('relu5_3', 1) ; 
largs = {'stride', [1 1], 'pad', [1 1 1 1]} ; sz = [3 3 512 512] ; addRelu = 1 ; 
rpn_conv = add_block(src, 'rpn_conv_3x3', opts, sz, addRelu, largs{:}) ;
numAnchors = numel(opts.modelOpts.scales) * numel(opts.modelOpts.ratios) ;

name = 'rpn_cls_score' ; largs = {'stride', [1 1], 'pad', [0 0 0 0]} ;  
c = 2 ; sz = [1 1 512 numAnchors*c ] ; addRelu = 0 ;
rpn_cls = add_block(rpn_conv, name, opts, sz, addRelu, largs{:}) ;

name = 'rpn_bbox_pred' ; largs = {'stride', [1 1], 'pad', [0 0 0 0]} ;
b = 4 ; sz = [1 1 512 numAnchors*b ] ; addRelu = 0 ;
rpn_bbox_pred = add_block(rpn_conv, name, opts, sz, addRelu, largs{:}) ;

largs = {'name', 'rpn_cls_score_reshape'} ;
args = {rpn_cls, [0 -1 c 0]} ; 
rpn_cls_reshape = Layer.create(@vl_nnreshape, args, largs{:}) ;

args = {rpn_cls, gtBoxes, imInfo} ; % note: first input used to determine shape
[rpn_labels, rpn_bbox_targets, rpn_iw, rpn_ow, rpn_cw] = ...
                 Layer.create(@vl_nnanchortargets, args) ;
rpn_labels.name = 'rpn_labels' ;
%rpn_bbox_targets.name = 'rpn_bbox_targets' ;
%rpn_in_w.name = 'rpn_bbox_inside_weights' ;
%rpn_out.name = 'rpn_bbox_outside_weights' ;

% rpn losses
args = {rpn_cls_reshape, rpn_labels, 'instanceWeights', rpn_cw} ;
largs = {'name', 'rpn_loss_cls', 'numInputDer', 1} ;
rpn_loss_cls = Layer.create(@vl_nnloss, args, largs{:}) ;

weighting = {'insideWeights', rpn_iw, 'outsideWeights', rpn_ow} ;
args = [{rpn_bbox_pred, rpn_bbox_targets, 'sigma', 3}, weighting] ;
largs = {'name', 'rpn_loss_bbox', 'numInputDer', 1} ;
rpn_loss_bbox = Layer.create(@vl_nnsmoothL1loss, args, largs{:}) ;

args = {rpn_loss_cls, rpn_loss_bbox, 'locWeight', opts.modelOpts.locWeight} ;
largs = {'name', 'rpn_multitask_loss'} ;
rpn_multitask_loss = Layer.create(@vl_nnmultitaskloss, args, largs{:}) ;

% RoI proposals 
largs = {'name', 'rpn_cls_prob'} ;
rpn_cls_prob = Layer.create(@vl_nnsoftmax, {rpn_cls_reshape}, largs{:}) ;

args = {rpn_cls_prob, [0 -1 numAnchors*c 0]} ; 
largs = {'name', 'rpn_cls_prob_reshape'} ; 
rpn_cls_prob_reshape = Layer.create(@vl_nnreshape, args, largs{:}) ;

proposalConf = {'postNMSTopN', 2000, 'preNMSTopN', 12000} ;
featOpts = [{'featStride', opts.modelOpts.featStride}, proposalConf] ;
args = {rpn_cls_prob_reshape, rpn_bbox_pred, imInfo, featOpts{:}} ; %#ok
proposals = Layer.create(@vl_nnproposalrpn, args, largs{:}) ;

args = {proposals, gtBoxes, gtLabels, 'numClasses', opts.modelOpts.numClasses} ;
largs = {'name', 'roi_data', 'numInputDer', 1} ;
[rois, labels, bbox_targets, bbox_in_w, bbox_out_w] = ...
                 Layer.create(@vl_nnproposaltargets, args, largs{:}) ;

% reattach fully connected layers following roipool
largs = {'name', 'roi_pool5'} ;
args = {src, rois, 'method', 'max', 'subdivisions', [7,7], 'transform', 1/16} ;
roi_pool = Layer.create(@vl_nnroipool, args, largs{:}) ;
tail = net.find('fc6',1) ; tail.inputs{1} = roi_pool ;

% insert dropout layers
relu6 = net.find('relu6', 1) ; largs = {'name', 'drop6'} ;
drop6 = Layer.create(@vl_nndropout, {relu6, 'rate' 0.5}, largs{:}) ;
tail = net.find('fc7',1) ; tail.inputs{1} = drop6 ;

relu7 = net.find('relu7', 1) ; largs = {'name', 'drop7'} ;
drop7 = Layer.create(@vl_nndropout, {relu7, 'rate' 0.5}, largs{:}) ;

% final predictions
largs = {'stride', [1 1], 'pad', [0 0 0 0]} ;
sz = [1 1 4096 opts.modelOpts.numClasses] ; 
cls_score = add_block(drop7, 'cls_score', opts, sz, 0, largs{:}) ;

largs = {'stride', [1 1], 'pad', [0 0 0 0]} ;
sz = [1 1 4096 opts.modelOpts.numClasses*4] ; 
bbox_pred = add_block(drop7, 'bbox_pred', opts, sz, 0, largs{:}) ;

% r-cnn losses
largs = {'name', 'loss_cls', 'numInputDer', 1} ;
loss_cls = Layer.create(@vl_nnloss, {cls_score, labels}, largs{:}) ;

weighting = {'insideWeights', bbox_in_w, 'outsideWeights', bbox_out_w} ;
args = [{bbox_pred, bbox_targets, 'sigma', 1}, weighting] ;
largs = {'name', 'loss_bbox', 'numInputDer', 1} ;
loss_bbox = Layer.create(@vl_nnsmoothL1loss, args, largs{:}) ;

args = {loss_cls, loss_bbox, 'locWeight', opts.modelOpts.locWeight} ;
largs = {'name', 'multitask_loss'} ;
multitask_loss = Layer.create(@vl_nnmultitaskloss, args, largs{:}) ;

if 1 % init from caffe weights
  pVals = load('net.mat') ;
  fnames = fieldnames(pVals) ;
  for ff = 1:numel(fnames)
    fname = fnames{ff} ;
    pNum = str2double(fname(end)) + 2 ; % find position (+1 MATLAB & +1 input pos)
    fname_ = fname(1:end-2) ;
    fprintf('updating %s:%d\n', fname_, pNum) ;
    order = [3 4 2 1] ;
    if contains(fname, 'rpn') 
      newVal = permute(pVals.(fname), order) ;
      rpn_multitask_loss.find(fname_, 1).inputs{pNum}.value = newVal ;
    else % handle second fork
      newVal = permute(pVals.(fname), order) ;
      if strcmp(fname, 'conv1_1_0')
        newVal = newVal(:,:,[3 2 1],:) ;
      end
      multitask_loss.find(fname_, 1).inputs{pNum}.value = newVal ;
    end
  end
end

net = Net(rpn_multitask_loss, multitask_loss) ;
net_ = net.saveobj() ; save('cNet.mat', '-struct', 'net_') ;
keyboard

% ---------------------------------------------------------------------
function net = add_block(net, name, opts, sz, nonLinearity, varargin)
% ---------------------------------------------------------------------

filters = Param('value', init_weight(sz, 'single'), 'learningRate', 1) ;
biases = Param('value', zeros(sz(4), 1, 'single'), 'learningRate', 2) ;
cudaOpts = {'CudnnWorkspaceLimit', opts.modelOpts.CudnnWorkspaceLimit} ;
net = vl_nnconv(net, filters, biases, varargin{:}, cudaOpts{:}) ;
net.name = name ;

if nonLinearity
  bn = opts.modelOpts.batchNormalization ;
  rn = opts.modelOpts.batchRenormalization ;
  assert(bn + rn < 2, 'cannot add both batch norm and renorm') ;
  if bn
    net = vl_nnbnorm(net, 'learningRate', [2 1 0.05], 'testMode', false) ;
    net.name = sprintf('%s_bn', name) ;
  elseif rn
    net = vl_nnbrenorm_auto(net, opts.clips, opts.renormLR{:}) ; 
    net.name = sprintf('%s_rn', name) ;
  end
  net = vl_nnrelu(net) ;
  net.name = sprintf('%s_relu', name) ;
end

% -------------------------------------------------------------------------
function weights = init_weight(sz, type)
% -------------------------------------------------------------------------
% See K. He, X. Zhang, S. Ren, and J. Sun. Delving deep into
% rectifiers: Surpassing human-level performance on imagenet
% classification. CoRR, (arXiv:1502.01852v1), 2015.

%sc = sqrt(2/(sz(1)*sz(2)*sz(4))) ;  
sc = sqrt(1/(sz(1)*sz(2)*sz(3))) ;
weights = randn(sz, type)*sc ;

% ----------------------------------------------
function net = matchCaffeBiases(net, param)
% ----------------------------------------------
% set the learning rate and weight decay of the 
% convolution biases to match caffe
net.params(net.getParamIndex(param)).learningRate = 2 ;
net.params(net.getParamIndex(param)).weightDecay = 0 ;