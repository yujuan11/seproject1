from distutils.core import setup
from Cython.Build import cythonize

setup(ext_modules=cythonize("ll_cython.pyx",annotate=True))





